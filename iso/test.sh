#!/bin/bash
# Install a Bande ISO unattended in QEMU, boot the installed system and check
# that it reaches a login prompt with the expected packages and apt source.
#
# Usage: iso/test.sh <amd64|arm64> <iso> [log-dir]
# amd64 uses KVM when /dev/kvm exists, otherwise TCG; arm64 uses TCG and AAVMF.
# The ISO itself stays unattended-free: the answers go into a copy of its
# initrd, and the kernel boots from that copy with the ISO's own parameters.
set -euo pipefail

arch=${1:?usage: iso/test.sh <amd64|arm64> <iso>}
iso=$(realpath "${2:?usage: iso/test.sh <amd64|arm64> <iso>}")
here=$(dirname "$(realpath "$0")")
logs=$(realpath -m "${3:-test-logs}")
work=$(mktemp -d)
qpid=
# Keep the serial logs, without terminal control sequences.
save_logs() {
    mkdir -p "$logs"
    for l in install boot; do
        [ -f "$work/$l.log" ] || continue
        sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$work/$l.log" | tr -cd '[:print:]\n' > "$logs/$arch-$l.log"
    done
}
trap '[ -n "$qpid" ] && kill "$qpid" 2>/dev/null; save_logs; rm -rf "$work"' EXIT
cd "$work"

die() { echo "test.sh: $*" >&2; exit 1; }

case $arch in
amd64)
    installdir=install.amd console=ttyS0,115200n8
    qemu=(qemu-system-x86_64 -machine q35 -smp 4 -m 3072)
    if [ -w /dev/kvm ]; then qemu+=(-accel kvm -cpu host); accel=kvm
    else qemu+=(-accel tcg -cpu max); accel=tcg; fi
    code=/usr/share/OVMF/OVMF_CODE_4M.fd vars=/usr/share/OVMF/OVMF_VARS_4M.fd
    cdrom=(-drive file="$iso",media=cdrom,readonly=on,if=none,id=cd -device ide-cd,drive=cd)
    ;;
arm64)
    installdir=install.a64 console=ttyAMA0
    qemu=(qemu-system-aarch64 -machine virt,gic-version=max -accel tcg
        -cpu max,pauth-impdef=on -smp 4 -m 3072)
    accel=tcg
    code=/usr/share/AAVMF/AAVMF_CODE.fd vars=/usr/share/AAVMF/AAVMF_VARS.fd
    cdrom=(-device virtio-scsi-pci,id=scsi
        -drive file="$iso",media=cdrom,readonly=on,if=none,id=cd -device scsi-cd,drive=cd)
    ;;
*) die "unsupported architecture: $arch" ;;
esac
if [ $accel = kvm ]; then install_limit=3600 boot_limit=600
else install_limit=12600 boot_limit=2400; fi
echo "QEMU $arch with $accel"

cp "$vars" vars.fd
qemu-img create -q -f qcow2 disk.qcow2 20G
qemu+=(-drive if=pflash,format=raw,readonly=on,file="$code" -drive if=pflash,format=raw,file=vars.fd
    -drive if=virtio,file=disk.qcow2,cache=unsafe
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0
    -device virtio-rng-pci -display none -monitor none)

xorriso -osirrox on -indev "$iso" -extract /$installdir/vmlinuz vmlinuz \
    -extract /$installdir/initrd.gz initrd.gz -extract /boot/grub/grub.cfg grub.cfg \
    -extract /simple-cdd/bande.preseed bande.preseed 2>/dev/null
chmod u+w initrd.gz

# The text "Install" entry: the ISO's own parameters, without the display ones.
line=$(grep -m1 -E "^\s*linux\s+/$installdir/vmlinuz" grub.cfg) || die "no install entry in grub.cfg"
params=
for p in ${line#*vmlinuz}; do
    case $p in vga=*|quiet|---|theme=*) ;; *) params+=" $p" ;; esac
done
case $params in *preseed/file=/cdrom/simple-cdd/default.preseed*) ;; *) die "ISO does not load the simple-cdd preseed: $params" ;; esac
case $params in *simple-cdd/profiles=bande*) ;; *) die "ISO does not select the bande profile: $params" ;; esac

packages=$(sed -n 's/^d-i pkgsel\/include string *//p' bande.preseed)
apt=no
grep -q '^d-i apt-setup/local0/repository' bande.preseed && apt=yes
echo "ISO preseed: Bande archive $apt, packages: ${packages:-none}"

mkdir initrd-extra
cp "$here/test.preseed" initrd-extra/preseed.cfg
# Copy the installer's syslog to the serial console, so failures show their
# cause. The initrd has merged /usr: lib is a symlink the cpio must not replace.
mkdir -p initrd-extra/usr/lib/debian-installer-startup.d
cat > initrd-extra/usr/lib/debian-installer-startup.d/S99bande-test-syslog <<'EOT'
(while [ ! -e /var/log/syslog ]; do sleep 1; done
 tail -n +1 -f /var/log/syslog | sed 's/^/SYSLOG: /') > /dev/console 2>&1 &
EOT
sed "s|@PACKAGES@|$packages|" "$here/test-late.sh" > initrd-extra/bande-test-late.sh
(cd initrd-extra && find . -mindepth 1 | cpio -o -H newc --quiet | gzip) > extra.cpio.gz
cat initrd.gz extra.cpio.gz > initrd-test.gz

# The installer's syslog and the last messages, without screen updates.
tail_log() {
    sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$1" | tr -cd '[:print:]\n' |
        grep -a -e '^SYSLOG: ' -e 'BANDE-' -e 'login:' | tail -120
}

# Wait for QEMU to exit or a pattern to appear in the serial log.
wait_for() {
    local log=$1 limit=$2 pattern=$3 start=$SECONDS next=300
    while kill -0 "$qpid" 2>/dev/null; do
        if [ -n "$pattern" ] && grep -aq "$pattern" "$log" 2>/dev/null; then return 0; fi
        if grep -saq -e '!! ERROR' -e 'Kernel panic' "$log"; then
            sleep 10
            echo "Error in $log:"; grep -sa -m3 -e '!! ERROR' -e 'Kernel panic' "$log"; echo "End of $log:"
            tail_log "$log"
            return 1
        fi
        if [ $((SECONDS - start)) -ge $limit ]; then
            echo "Timed out after $limit s; end of $log:"
            tail_log "$log"
            return 1
        fi
        if [ $((SECONDS - start)) -ge $next ]; then
            echo "  $((next / 60)) min: $(tail -c 2000 "$log" | tr -cd '[:print:]\n' | grep -a . | tail -1 | cut -c1-150)"
            next=$((next + 300))
        fi
        sleep 5
    done
    qpid=
    [ -z "$pattern" ]
}

echo "Installing..."
start=$SECONDS
"${qemu[@]}" "${cdrom[@]}" -no-reboot -kernel vmlinuz -initrd initrd-test.gz \
    -append "$params priority=critical DEBIAN_FRONTEND=text console=$console --- console=$console" \
    -serial file:install.log &
qpid=$!
if ! wait_for install.log $install_limit ""; then
    echo "Install did not finish"; exit 1
fi
install_time=$((SECONDS - start))
grep -aq "BANDE-TEST-LATE: done" install.log || {
    echo "The installer stopped before its late command; end of install.log:"
    tail_log install.log
    exit 1
}
echo "Installed in $install_time s"

echo "Booting the installed system..."
start=$SECONDS
"${qemu[@]}" -serial file:boot.log &
qpid=$!
wait_for boot.log $boot_limit "BANDE-TEST-BOOTED" || { echo "The installed system did not report"; exit 1; }
wait_for boot.log 120 "login:" || { echo "No login prompt"; exit 1; }
boot_time=$((SECONDS - start))
kill "$qpid"; qpid=

grep -a "BANDE-TEST-" boot.log | tr -cd '[:print:]\n'
fail=0
check() { grep -aq "$1" boot.log || { echo "missing: $1"; fail=1; }; }
check "BANDE-TEST-BOOTED: running"
check "BANDE-TEST-EFI: yes"
if [ $apt = yes ]; then check "BANDE-TEST-APT: .*bande-linux.github.io/apt"; fi
for p in $packages; do check "BANDE-TEST-PACKAGE: $p "; done
echo "install $install_time s, first boot $boot_time s ($arch, $accel)"
exit $fail
