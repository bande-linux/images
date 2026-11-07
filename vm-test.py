#!/usr/bin/env python3
import argparse
import os
import sys
import time

import vm


def login_shell(machine):
    machine.wait(r"sh-[0-9.]+#|root@[^ ]*:.*#", 600)
    machine.serial.sendall(b"PS1='# '; exec 2>&1; stty -echo\n")
    time.sleep(1)


def boot_finished(machine):
    machine.run("systemctl is-system-running --wait || true", 900)


def wait_for(machine, command, tries=90):
    for _ in range(tries):
        if machine.run(f"{command} || true").strip():
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
        wait_for(machine, "pgrep -u recovery bande-composi")
        time.sleep(8)
        machine.screenshot(os.path.join(args.work, "recovery.png"))
        print(machine.run("/usr/libexec/bande-install install /dev/vdb", 1800))
        print(machine.run("lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,LABEL"))
    finally:
        machine.stop()
    return usb, disk


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
        wait_for(machine, "id tester")
        time.sleep(4)
        machine.screenshot(os.path.join(args.work, "first-run-look.png"))
        machine.keys("ret")
        time.sleep(3)
        machine.screenshot(os.path.join(args.work, "first-run-privacy.png"))
        machine.keys("ret")
        wait_for(machine, "pgrep -u tester bande-composi")
        time.sleep(10)
        machine.screenshot(os.path.join(args.work, "desktop.png"))
        print(machine.run("id tester; ls -A /var/lib/bande; cat /home/tester/.config/bande/config.kdl; localectl status | head -3; loginctl list-sessions --no-legend; touch /home/tester/keep-me; chown tester: /home/tester/keep-me"))
        assert machine.run("ls -A /var/lib/bande | grep -c setup-pending || true").strip() == "0"
    finally:
        machine.stop()


def reinstall_flow(args, usb, disk, machine_args):
    machine = vm.Machine(args.arch, [{"path": usb}, {"path": disk}], **machine_args)
    try:
        login_shell(machine)
        boot_finished(machine)
        print(machine.run("printf 'bande-provisional\\n' | /usr/libexec/bande-install reinstall", 1800))
    finally:
        machine.stop()
    machine = vm.Machine(args.arch, [{"path": disk}], **machine_args)
    try:
        login_shell(machine)
        boot_finished(machine)
        print(machine.run("cat /proc/cmdline; ls -la /home/tester/keep-me; btrfs subvolume list / | head; id tester"))
    finally:
        machine.stop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("arch", choices=["arm64", "amd64"])
    parser.add_argument("image")
    parser.add_argument("work")
    parser.add_argument("--tcg", action="store_true")
    args = parser.parse_args()
    os.makedirs(args.work, exist_ok=True)
    machine_args = {"kvm": not args.tcg and os.access("/dev/kvm", os.W_OK)}
    usb, disk = install_flow(args, machine_args)
    first_run_flow(args, disk, machine_args)
    reinstall_flow(args, usb, disk, machine_args)
    return 0


sys.exit(main())
