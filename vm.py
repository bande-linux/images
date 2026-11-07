#!/usr/bin/env python3
import json
import os
import re
import select
import shutil
import socket
import subprocess
import tempfile
import time


class Machine:
    def __init__(self, arch, disks, cmdline="", memory=4096, kvm=True, firmware_framebuffer=False):
        self.work = tempfile.mkdtemp(prefix="bande-vm-")
        self.arch = arch
        self.console = "ttyAMA0" if arch == "arm64" else "ttyS0"
        vars_file = os.path.join(self.work, "vars.fd")
        if arch == "arm64":
            shutil.copy("/usr/share/AAVMF/AAVMF_VARS.no-secboot.fd" if os.path.exists("/usr/share/AAVMF/AAVMF_VARS.no-secboot.fd") else "/usr/share/AAVMF/AAVMF_VARS.fd", vars_file)
            code = "/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd"
            base = ["qemu-system-aarch64", "-machine", "virt,gic-version=max,its=off", "-cpu", "host" if kvm else "max"]
        else:
            shutil.copy("/usr/share/OVMF/OVMF_VARS_4M.fd", vars_file)
            code = "/usr/share/OVMF/OVMF_CODE_4M.fd"
            base = ["qemu-system-x86_64", "-machine", "q35", "-cpu", "host" if kvm else "max"]
        if kvm:
            base += ["-accel", "kvm"]
        self.qmp_path = os.path.join(self.work, "qmp")
        self.serial_path = os.path.join(self.work, "serial")
        extra = f"console={self.console} systemd.debug_shell={self.console} systemd.getty_auto=0 {cmdline}".strip()
        args = base + [
            "-smp", "4", "-m", str(memory),
            "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
            "-drive", f"if=pflash,format=raw,file={vars_file}",
            *(["-device", "ramfb"] if firmware_framebuffer else []),
            "-device", "virtio-gpu-pci", "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet",
            "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0,romfile=",
            "-smbios", f"type=11,value=io.systemd.boot.kernel-cmdline-extra={extra}",
            "-display", "none",
            "-qmp", f"unix:{self.qmp_path},server=on,wait=off",
            "-chardev", f"socket,id=serial0,path={self.serial_path},server=on,wait=off,logfile={self.work}/serial.log",
            "-serial", "chardev:serial0",
        ]
        for index, disk in enumerate(disks):
            args += ["-drive", f"if=virtio,format={disk.get('format', 'qcow2')},file={disk['path']}"]
        self.process = subprocess.Popen(args)
        for _ in range(100):
            if os.path.exists(self.qmp_path) and os.path.exists(self.serial_path):
                break
            time.sleep(0.1)
        self.qmp = socket.socket(socket.AF_UNIX)
        self.qmp.connect(self.qmp_path)
        self.qmp_file = self.qmp.makefile("rw")
        self.qmp_file.readline()
        self.command("qmp_capabilities")
        self.serial = socket.socket(socket.AF_UNIX)
        self.serial.connect(self.serial_path)
        self.buffer = b""

    def command(self, name, **arguments):
        self.qmp_file.write(json.dumps({"execute": name, "arguments": arguments}) + "\n")
        self.qmp_file.flush()
        while True:
            reply = json.loads(self.qmp_file.readline())
            if "return" in reply:
                return reply["return"]
            if "error" in reply:
                raise RuntimeError(reply["error"])

    def wait(self, pattern, timeout=600):
        deadline = time.monotonic() + timeout
        regex = re.compile(pattern.encode())
        while True:
            match = regex.search(self.buffer)
            if match:
                self.buffer = self.buffer[match.end():]
                return match
            left = deadline - time.monotonic()
            if left <= 0 or self.process.poll() is not None:
                tail = self.buffer[-3000:].decode(errors="replace")
                raise TimeoutError(f"waiting for {pattern}\n{tail}")
            ready, _, _ = select.select([self.serial], [], [], min(left, 5))
            if ready:
                self.buffer += self.serial.recv(65536)

    def drain(self, seconds):
        deadline = time.monotonic() + seconds
        while (left := deadline - time.monotonic()) > 0:
            ready, _, _ = select.select([self.serial], [], [], left)
            if ready:
                self.buffer += self.serial.recv(65536)

    def run(self, command, timeout=600):
        marker = f"E{time.monotonic_ns()}"
        self.buffer = b""
        self.serial.sendall(f"( {command} ) 2>&1 | sed 's/^/| /'; echo {marker}=${{PIPESTATUS[0]}}=\n".encode())
        match = self.wait(rf"(?s)\n((?:\| [^\n]*\n)*)[^\n]*{marker}=(\d+)=", timeout)
        output = re.sub(r"(?m)^\| ", "", match.group(1).decode(errors="replace")).replace("\r", "")
        status = int(match.group(2))
        if status:
            raise RuntimeError(f"{command} failed with {status}\n{output}")
        return output

    def screenshot(self, path):
        self.command("screendump", filename=path, format="png")

    def keys(self, *names):
        events = [{"type": "qcode", "data": name} for name in names]
        self.command("send-key", keys=events)

    def type(self, text):
        names = {" ": ["spc"], "-": ["minus"], ".": ["dot"], "\n": ["ret"], "\t": ["tab"]}
        for char in text:
            if char in names:
                self.keys(*names[char])
            elif char.isupper():
                self.keys("shift", char.lower())
            else:
                self.keys(char)
            time.sleep(0.05)

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(30)
        shutil.rmtree(self.work, ignore_errors=True)


def blank_disk(path, size):
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", path, size], check=True)


def overlay(path, backing):
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-F", "raw", "-b", backing, path], check=True)
