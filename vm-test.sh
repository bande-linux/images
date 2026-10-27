#!/bin/bash
set -euo pipefail

test=$(realpath "$1")
work=$(mktemp -d)
qpid=
trap '[ -n "$qpid" ] && kill "$qpid" 2>/dev/null; rm -rf "$work"' EXIT
cd "$work"

qemu-img create -q -f qcow2 -F raw -b "$test/disk.img" overlay.qcow2

machine=(-machine virt,gic-version=max,its=off -accel kvm -cpu host -smp 2 -m 2048
    -drive if=virtio,file=overlay.qcow2
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile=
    -display none -monitor none)

qemu-system-aarch64 "${machine[@]}" -machine dumpdtb=virt.dtb
fdtput -t s virt.dtb /chosen unbound,efi-system-partition "$(cat "$test/esp-partuuid")"

qemu-system-aarch64 "${machine[@]}" -dtb virt.dtb \
    -kernel "$test/vmlinuz" -initrd "$test/initrd.img" \
    -append "root=UUID=$(cat "$test/root-uuid") rw console=ttyAMA0" \
    -serial file:serial.log &
qpid=$!

start=$SECONDS
until grep -q "UNBOUND-TEST-DONE" serial.log 2>/dev/null; do
    if ! kill -0 "$qpid" 2>/dev/null; then
        echo "QEMU exited before the test finished"
        cat serial.log
        exit 1
    fi
    if [ $((SECONDS - start)) -gt 300 ]; then
        echo "Timed out waiting for the guest"
        cat serial.log
        exit 1
    fi
    sleep 2
done

echo "Guest finished after $((SECONDS - start)) s"
grep -a "UNBOUND-TEST\|Unbound:" serial.log
grep -aq "UNBOUND-TEST-FW: unbound-test-firmware" serial.log
grep -aq "UNBOUND-TEST-NET: .*routable" serial.log
