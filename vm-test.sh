#!/bin/bash
set -euo pipefail

test=$(realpath "$1")
work=$(mktemp -d)
qpid=
trap '[ -n "$qpid" ] && kill "$qpid" 2>/dev/null; rm -rf "$work"' EXIT
cd "$work"

qemu-img create -q -f qcow2 -F raw -b "$test/disk.img" overlay.qcow2

machine=(-machine virt,gic-version=max,its=off -accel kvm -cpu host -smp 2 -m 4096
    -drive if=virtio,file=overlay.qcow2
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile=
    -display none -monitor none)

qemu-system-aarch64 "${machine[@]}" -machine dumpdtb=virt.dtb
fdtput -t s virt.dtb /chosen bande,efi-system-partition "$(cat "$test/esp-partuuid")"

qemu-system-aarch64 "${machine[@]}" -dtb virt.dtb \
    -kernel "$test/vmlinuz" -initrd "$test/initrd.img" \
    -append "root=UUID=$(cat "$test/root-uuid") rw console=ttyAMA0" \
    -serial file:serial.log &
qpid=$!

start=$SECONDS
until grep -q "BANDE-TEST-DONE" serial.log 2>/dev/null; do
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
grep -a "BANDE-TEST\|Bande:" serial.log
fail=0
check() { grep -aq "$1" serial.log || { echo "missing: $1"; fail=1; }; }
check "BANDE-TEST-FW: bande-test-firmware"
check "BANDE-TEST-NET: .*ethernet:connected"
check "BANDE-TEST-USER: tester .*sudo"
check "BANDE-TEST-USER: tester .*render"
check "BANDE-TEST-SSH: key-login"
check "BANDE-TEST-SSHD: .*passwordauthentication no"
check "BANDE-TEST-WIFI: .*Bande Test:802-11-wireless"
check "BANDE-TEST-SETUP:"
grep -a "BANDE-TEST-SETUP:" serial.log | grep -q setup && { echo "setup data left on the ESP"; fail=1; }
check "BANDE-TEST-SESSION: .*tester seat0"
check "BANDE-TEST-COMPOSITOR: [0-9]"
exit $fail
