#!/usr/bin/env python3
import argparse
import os
import subprocess
import sys
import time

import vm


MAC_RECOVERY_PARTUUID = "5e6f7a8b-1c2d-4e3f-8a9b-0c1d2e3f4a5b"


def login_shell(machine):
    machine.wait(r"sh-[0-9.]+#|root@[^ ]*:.*#", 600)
    machine.serial.sendall(b"PS1='# '; exec 2>&1; stty -echo\n")
    time.sleep(1)


def boot_finished(machine):
    machine.run("systemctl is-system-running --wait || true", 900)


def wait_for(machine, command, tries=90):
    for _ in range(tries):
        if machine.run(f"{command} 2>/dev/null || true").strip():
            return
        time.sleep(2)
    raise TimeoutError(command)


def install_flow(args, machine_args):
    usb = os.path.join(args.work, "usb.qcow2")
    disk = os.path.join(args.work, "disk.qcow2")
    vm.overlay(usb, os.path.abspath(args.image))
    vm.blank_disk(disk, "40G")
    machine = vm.Machine(args.arch, [{"path": usb}, {"path": disk}], **machine_args)
    try:
        login_shell(machine)
        boot_finished(machine)
        print(machine.run("cat /run/bande-live/device; findmnt -no SOURCE,FSTYPE /; id recovery"))
        wait_for(machine, "pgrep -u recovery bande-recovery")
        time.sleep(10)
        print(machine.run("pgrep -au recovery | cut -c1-80; runuser -u recovery -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user --no-pager status 'app-*' 2>&1 | head -20; journalctl --user -M recovery@ -n 20 --no-pager 2>&1 | tail -20 | cut -c1-160"))
        machine.screenshot(os.path.join(args.work, "recovery.png"))
        print(machine.run("/usr/libexec/bande-install install /dev/vdb", 3600))
        print(machine.run("lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,LABEL"))
    finally:
        machine.stop()
    return usb, disk


def install_only_flow(args, machine_args):
    usb = os.path.join(args.work, "usb.qcow2")
    disk = os.path.join(args.work, "disk.qcow2")
    vm.overlay(usb, os.path.abspath(args.image))
    vm.blank_disk(disk, "40G")
    machine = vm.Machine(args.arch, [{"path": usb}, {"path": disk}], **machine_args)
    try:
        login_shell(machine)
        boot_finished(machine)
        print(machine.run("uname -m; cat /run/bande-live/device; /usr/libexec/bande-install install /dev/vdb", 3600))
    finally:
        machine.stop()
    machine = vm.Machine(args.arch, [{"path": disk}], **machine_args)
    try:
        login_shell(machine)
        boot_finished(machine)
        print(machine.run("uname -m; findmnt -no SOURCE,FSTYPE,OPTIONS /; cat /proc/cmdline; cryptsetup status bande-root | head -5; bootctl list --no-pager | grep -E 'title'; systemctl --failed --no-legend | head; pgrep -au _greetd | head -5"))
        machine.screenshot(os.path.join(args.work, "installed.png"))
    finally:
        machine.stop()


def first_run_flow(args, disk, machine_args):
    machine = vm.Machine(args.arch, [{"path": disk}], **machine_args)
    try:
        login_shell(machine)
        boot_finished(machine)
        print(machine.run("findmnt -no SOURCE,FSTYPE,OPTIONS /; findmnt -no SOURCE /home; cat /proc/cmdline; cryptsetup status bande-root | head -5; cryptsetup token export --token-id 0 /dev/disk/by-label/BANDE-ROOT; bootctl list --no-pager | grep -E 'title|source' ; systemctl --failed --no-legend | head"))
        wait_for(machine, "pgrep -u _greetd bande-setup")
        time.sleep(6)
        machine.screenshot(os.path.join(args.work, "first-run-language.png"))
        machine.keys("ret")
        time.sleep(4)
        machine.screenshot(os.path.join(args.work, "first-run-keyboard.png"))
        machine.keys("ret")
        time.sleep(4)
        machine.type("Test User")
        machine.keys("tab")
        machine.type("tester")
        machine.keys("tab")
        machine.type("testpass")
        machine.keys("tab")
        machine.type("testpass")
        machine.screenshot(os.path.join(args.work, "first-run-account.png"))
        machine.keys("ret")
        try:
            wait_for(machine, "id tester", 30)
        except TimeoutError:
            machine.screenshot(os.path.join(args.work, "first-run-stuck.png"))
            print(machine.run("journalctl -n 30 --no-pager | cut -c1-200"))
            raise
        time.sleep(4)
        machine.screenshot(os.path.join(args.work, "first-run-recovery-key.png"))
        machine.keys("ret")
        time.sleep(4)
        machine.screenshot(os.path.join(args.work, "first-run-look.png"))
        machine.keys("ret")
        time.sleep(3)
        machine.screenshot(os.path.join(args.work, "first-run-privacy.png"))
        machine.keys("ret")
        wait_for(machine, "pgrep -u tester bande-composi")
        time.sleep(10)
        machine.screenshot(os.path.join(args.work, "desktop.png"))
        print(machine.run("id tester; ls -A /var/lib/bande; cat /home/tester/.config/bande/config.kdl; localectl status | head -3; loginctl list-sessions --no-legend; sync"))
        assert machine.run("ls -A /var/lib/bande | grep -c setup-pending || true").strip() == "0"
    finally:
        machine.stop()


def encrypted_boot_flow(args, disk, machine_args):
    machine = vm.Machine(args.arch, [{"path": disk}], **machine_args)
    try:
        machine.drain(60)
        machine.screenshot(os.path.join(args.work, "unlock-prompt.png"))
        machine.type("wrongpass\n")
        machine.wait("bad password", 300)
        machine.drain(15)
        machine.screenshot(os.path.join(args.work, "unlock-wrong.png"))
        machine.type("testpass\n")
        login_shell(machine)
        boot_finished(machine)
        wait_for(machine, "pgrep -u tester bande-composi", 45)
        machine.drain(10)
        machine.screenshot(os.path.join(args.work, "after-unlock.png"))
        machine.run("touch /home/tester/keep-me; chown tester: /home/tester/keep-me; sync")
        print(machine.run("cat /run/bande-disk-encryption/status; loginctl list-sessions --no-legend; cryptsetup luksDump /dev/disk/by-label/BANDE-ROOT | grep -E '^  [0-9]: luks2|Tokens' | head"))
    finally:
        machine.stop()


def reinstall_flow(args, usb, disk, machine_args):
    machine = vm.Machine(args.arch, [{"path": usb}, {"path": disk}], **machine_args)
    try:
        login_shell(machine)
        boot_finished(machine)
        print(machine.run("printf 'testpass\\n' | /usr/libexec/bande-install reinstall", 1800))
    finally:
        machine.stop()
    machine = vm.Machine(args.arch, [{"path": disk}], **machine_args)
    try:
        machine.drain(60)
        machine.type("testpass\n")
        login_shell(machine)
        boot_finished(machine)
        print(machine.run("cat /proc/cmdline; findmnt -no SOURCE /home; ls -la /home/tester/keep-me; btrfs subvolume list / | head; id tester; ls -A /var/lib/bande; bootctl list --no-pager | grep -E ' id:|title:'"))
    finally:
        machine.stop()


def mac_disk(args, package):
    work = os.path.join(args.work, "mac")
    os.makedirs(work, exist_ok=True)
    subprocess.run(["unzip", "-q", "-o", os.path.abspath(package), "-d", work], check=True)
    recovery = os.path.join(work, "recovery.img")
    root = os.path.join(work, "root.img")
    esp_mib = 1024
    recovery_mib = 6144
    disk = os.path.join(args.work, "mac.raw")
    if os.path.exists(disk):
        os.unlink(disk)
    subprocess.run(["truncate", "-s", "30G", disk], check=True)
    table = (
        "label: gpt\n"
        f"start=1MiB, size={esp_mib}MiB, type=U\n"
        f"size={recovery_mib}MiB, type=L, uuid={MAC_RECOVERY_PARTUUID}\n"
        "type=L\n"
    )
    subprocess.run(["sfdisk", "-q", disk], input=table.encode(), check=True)
    esp = os.path.join(args.work, "mac-esp.img")
    if os.path.exists(esp):
        os.unlink(esp)
    subprocess.run(["mkfs.vfat", "-C", "-F", "32", "-i", "3c2e1a9b", esp, str(esp_mib * 1024)], check=True, stdout=subprocess.DEVNULL)
    entry = os.path.join(work, "esp", "loader", "entries", "recovery.conf")
    with open(entry, encoding="utf-8") as fd:
        text = fd.read()
    with open(entry, "w", encoding="utf-8") as fd:
        fd.write(text.replace("@RECOVERY_PARTUUID@", MAC_RECOVERY_PARTUUID))
    environment = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    for item in os.listdir(os.path.join(work, "esp")):
        subprocess.run(["mcopy", "-s", "-i", esp, os.path.join(work, "esp", item), "::/"], check=True, env=environment)
    for image, seek in ((esp, 1), (recovery, 1 + esp_mib), (root, 1 + esp_mib + recovery_mib)):
        subprocess.run(["dd", f"if={image}", f"of={disk}", "bs=1M", f"seek={seek}", "conv=notrunc,sparse", "status=none"], check=True)
    return disk


def mac_flow(args, machine_args):
    disk = mac_disk(args, args.image)
    machine = vm.Machine("arm64", [{"path": disk, "format": "raw"}], **machine_args)
    try:
        login_shell(machine)
        boot_finished(machine)
        print(machine.run("findmnt -no SOURCE,FSTYPE,SIZE /; cat /proc/cmdline; getconf PAGESIZE; uname -r; lsblk -o NAME,SIZE,FSTYPE; cryptsetup status bande-root | head -6; cryptsetup token export --token-id 0 /dev/vda3; ls /boot/efi/unboot /boot/efi/loader/entries; systemctl --failed --no-legend | head"))
        wait_for(machine, "pgrep -u _greetd bande-setup")
        time.sleep(10)
        machine.screenshot(os.path.join(args.work, "mac-first-run.png"))
    finally:
        machine.stop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("arch", choices=["arm64", "amd64"])
    parser.add_argument("image")
    parser.add_argument("work")
    parser.add_argument("--tcg", action="store_true")
    parser.add_argument("--mac", action="store_true")
    parser.add_argument("--install-only", action="store_true")
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    os.makedirs(args.work, exist_ok=True)
    machine_args = {"kvm": not args.tcg and os.access("/dev/kvm", os.W_OK)}
    if args.mac:
        mac_flow(args, {"kvm": False})
        return 0
    if args.install_only:
        install_only_flow(args, machine_args)
        return 0
    if args.resume:
        usb, disk = os.path.join(args.work, "usb.qcow2"), os.path.join(args.work, "disk.qcow2")
    else:
        usb, disk = install_flow(args, machine_args)
        first_run_flow(args, disk, machine_args)
    encrypted_boot_flow(args, disk, machine_args)
    reinstall_flow(args, usb, disk, machine_args)
    return 0


sys.exit(main())
