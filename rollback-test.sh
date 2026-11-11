#!/bin/bash
# Usage: rollback-test.sh <work dir> <u-boot.bin> <bande-system checkout> <kernel tar or "debian"> [scenario...]
# Boots a real disk under QEMU through U-Boot and systemd-boot, the Mac's boot chain after m1n1,
# and proves that a failed update comes back by itself. Needs root and /dev/kvm.
set -euo pipefail

work=$(realpath "$1")
uboot=$(realpath "$2")
scripts=$(realpath "$3")
kernel=$4
shift 4
here=$(cd "$(dirname "$0")" && pwd)
uuid=8a0b3f4e-6c1d-4e55-9b0a-2d7f1c3e5a61
esp_uuid=3C2E-1A9B
disk=$work/disk.img
port=${TEST_SSH_PORT:-2522}
key=$work/key
qpid=
fail=0

stop_vm() {
    if [ -n "$qpid" ]; then
        kill "$qpid" 2>/dev/null || true
        wait "$qpid" 2>/dev/null || true
        qpid=
    fi
}
trap stop_vm EXIT

note() { echo "== $*"; }

build_base() {
    [ -e "$work/base.img" ] && [ "$work/base.img" -nt "$scripts/bande-system" ] && return 0
    rm -rf "$work/root" "$work/esp"
    mkdir -p "$work"
    [ -e "$key" ] || ssh-keygen -q -t ed25519 -N '' -f "$key"
    local kernel_pkg=
    [ "$kernel" = debian ] && kernel_pkg=,linux-image-arm64
    mmdebstrap --variant=minbase --arch=arm64 --mode=root --format=directory \
        --components=main --skip=check/empty \
        --include="systemd-sysv,udev,dbus,kmod,initramfs-tools,zstd,btrfs-progs,dosfstools,systemd-boot,systemd-boot-efi,linux-base,openssh-server,iproute2,systemd-resolved,apt-utils,passwd,wireless-regdb$kernel_pkg" \
        forky "$work/root" "deb http://deb.debian.org/debian forky main"
    local root=$work/root
    if [ "$kernel" != debian ]; then
        tar -C "$root" -xf "$kernel" --keep-directory-symlink
    fi
    install -m 755 "$scripts/bande-system" "$root/usr/sbin/bande-system"
    install -m 755 "$scripts/update-unboot" "$root/usr/bin/update-unboot"
    mkdir -p "$root/usr/share/bande-scripts" "$root/usr/lib/kernel/install.d"
    install -m 644 "$scripts/functions.sh" "$root/usr/share/bande-scripts/"
    install -m 755 "$scripts/boot-assessment/90-bande-system.install" "$root/usr/lib/kernel/install.d/"
    install -m 644 "$scripts/boot-assessment/50-bande-system.conf" "$root/etc/apt/apt.conf.d/"
    install -m 644 "$scripts"/boot-assessment/*.service "$scripts"/boot-assessment/*.socket "$root/usr/lib/systemd/system/"
    mkdir -p "$root/usr/lib/systemd/system/emergency.service.d" "$root/usr/lib/systemd/system/rescue.service.d"
    install -m 644 "$scripts/boot-assessment/bande-counted-boot.conf" "$root/usr/lib/systemd/system/emergency.service.d/"
    install -m 644 "$scripts/boot-assessment/bande-counted-boot.conf" "$root/usr/lib/systemd/system/rescue.service.d/"
    echo layout=bande > "$root/etc/kernel/install.conf"
    echo "root=UUID=$uuid rw console=ttyAMA0" > "$root/etc/kernel/cmdline"
    echo debian > "$root/etc/kernel/entry-token"
    for name in hello-update bad-kernel bad-session bad-postinst bad-mount slow-update fast-update; do
        make_deb "$name" 1
        cp "$work/$name-1.deb" "$root/tmp/"
    done
    chroot "$root" sh -c 'dpkg -i /tmp/*-1.deb && rm -f /tmp/*-1.deb' >/dev/null
    cat > "$root/etc/fstab" <<EOT
UUID=$uuid / btrfs noatime,compress=zstd:1 0 0
UUID=$uuid /home btrfs subvol=@home,noatime,compress=zstd:1 0 0
UUID=$uuid /var/log btrfs subvol=@var-log,noatime,compress=zstd:1 0 0
UUID=$uuid /var/cache btrfs subvol=@var-cache,noatime,compress=zstd:1 0 0
UUID=$uuid /var/tmp btrfs subvol=@var-tmp,noatime,compress=zstd:1 0 0
UUID=$uuid /.snapshots btrfs subvol=@snapshots,noatime,compress=zstd:1 0 0
UUID=$esp_uuid /boot/efi vfat rw,umask=0077,nofail 0 2
EOT
    mkdir -p "$root/root/.ssh" "$root/srv/repo"
    install -m 600 "$key.pub" "$root/root/.ssh/authorized_keys"
    echo 'PermitRootLogin prohibit-password' > "$root/etc/ssh/sshd_config.d/test.conf"
    echo bande-test > "$root/etc/hostname"
    chroot "$root" sh -c 'echo root:original | chpasswd; useradd -m -G video tester; echo tester:original | chpasswd'
    cat > "$root/etc/systemd/network/80-test.network" <<'EOT'
[Match]
Name=en*
[Network]
DHCP=yes
EOT
    chroot "$root" systemctl enable systemd-networkd systemd-resolved ssh bande-system-first-boot.service bande-system-status.service
    chroot "$root" systemctl enable bande-login-ready.socket bande-boot-health.service
    mkdir -p "$root/etc/systemd/system/bande-boot-health.service.d"
    printf '[Service]\nTimeoutStartSec=45s\n' > "$root/etc/systemd/system/bande-boot-health.service.d/test.conf"
    cat > "$root/etc/systemd/system/test-login.service" <<'EOT'
[Unit]
Description=Stands in for the compositor telling the system the login window is up
After=multi-user.target
ConditionPathExists=!/etc/test-login-broken

[Service]
Type=oneshot
Environment=NOTIFY_SOCKET=/run/bande/login-ready
ExecStart=/usr/bin/systemd-notify --ready

[Install]
WantedBy=multi-user.target
EOT
    chroot "$root" systemctl enable test-login.service
    cat >> "$root/etc/initramfs-tools/modules" <<'EOT'
btrfs
virtio_pci
virtio_blk
vfat
EOT
    mount -t proc proc "$root/proc"
    mount --rbind /dev "$root/dev"
    mount --make-rslave "$root/dev"
    local version
    version=$(ls "$root/lib/modules" | head -1)
    chroot "$root" depmod "$version"
    chroot "$root" update-initramfs -c -k "$version"
    mkdir -p "$root/boot/efi"
    umount -R -l "$root/dev"
    umount "$root/proc"
    rm -f "$root/etc/ssh/ssh_host_"*
    chroot "$root" ssh-keygen -A

    mkdir -p "$work/esp/EFI/BOOT" "$work/esp/loader/entries" "$work/esp/bande/boot"
    cp "$root/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$work/esp/EFI/BOOT/BOOTAA64.EFI"
    printf 'timeout 0\n' > "$work/esp/loader/loader.conf"
    BANDE_ESP=$work/esp sh "$scripts/bande-system" first-entry "$root"

    "$here/mkroot.sh" "$root" "$work/root.img" "$uuid" 8192
    rm -f "$work/esp.img"
    mkfs.vfat -C -F 32 -i "$(echo "$esp_uuid" | tr -d -)" "$work/esp.img" $((1024 * 1024)) >/dev/null
    mcopy -s -i "$work/esp.img" "$work/esp"/* ::/
    local esp_sectors root_sectors
    esp_sectors=$(($(stat -c %s "$work/esp.img") / 512))
    root_sectors=$(($(stat -c %s "$work/root.img") / 512))
    rm -f "$work/base.img"
    truncate -s $(((2048 + esp_sectors + root_sectors + 2048) * 512)) "$work/base.img"
    sfdisk -q "$work/base.img" <<EOT
label: gpt
start=2048, size=$esp_sectors, type=U
start=$((2048 + esp_sectors)), size=$root_sectors, type=L
EOT
    dd if="$work/esp.img" of="$work/base.img" bs=1M seek=1 conv=notrunc,sparse status=none
    dd if="$work/root.img" of="$work/base.img" bs=512 seek=$((2048 + esp_sectors)) conv=notrunc,sparse status=none
    rm -f "$work/esp.img" "$work/root.img"
}

start_vm() {
    : > "$work/serial.log"
    qemu-system-aarch64 -machine virt,gic-version=max,its=off -accel "${TEST_ACCEL:-kvm}" -cpu "${TEST_CPU:-host}" -smp 4 -m 2048 \
        -bios "$uboot" \
        -drive "if=virtio,format=raw,file=$disk" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" -device virtio-net-pci,netdev=net0,romfile= \
        -display none -monitor none -serial "file:$work/serial.log" &
    qpid=$!
}

guest() {
    ssh -q -i "$key" -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 root@127.0.0.1 "$@"
}

wait_guest() {
    local limit=${1:-1200} start=$SECONDS
    until guest true 2>/dev/null; do
        kill -0 "$qpid" 2>/dev/null || { echo "QEMU exited"; return 1; }
        [ $((SECONDS - start)) -lt "$limit" ] || { echo "guest did not come up in $limit s"; tail -n 40 "$work/serial.log"; return 1; }
        sleep 3
    done
}

wait_blessed() {
    guest 'timeout 120 sh -c "until systemctl is-active -q systemd-bless-boot.service; do sleep 2; done"; ls /boot/efi/loader/entries'
}

expect() {
    local what=$1 want=$2 got=$3
    if [ "$got" = "$want" ]; then
        echo "ok: $what ($got)"
    else
        echo "FAILED: $what: wanted '$want', got '$got'"
        fail=1
    fi
}

running() { guest findmnt -no FSROOT /; }

make_deb() {
    local name=$1 version=$2 postinst=${3:-} dir
    dir=$(mktemp -d -p "$work")
    mkdir -p "$dir/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: t <t@t>\nDescription: test\n' "$name" "$version" > "$dir/DEBIAN/control"
    if [ -n "$postinst" ]; then
        printf '#!/bin/sh\n%s\n' "$postinst" > "$dir/DEBIAN/postinst"
        chmod 755 "$dir/DEBIAN/postinst"
    fi
    dpkg-deb -b --root-owner-group "$dir" "$work/$name-$version.deb" >/dev/null
    rm -rf "$dir"
}

add_update() {
    make_deb "$@"
    guest "cat > /srv/repo/$1-$2.deb" < "$work/$1-$2.deb"
    guest 'cd /srv/repo && apt-ftparchive packages . > Packages && apt-get update -qq'
}

prepare_guest_repo() {
    guest 'echo "deb [trusted=yes] file:/srv/repo ./" > /etc/apt/sources.list.d/test.list; rm -f /etc/apt/sources.list; cd /srv/repo && apt-ftparchive packages . > Packages && apt-get update -qq'
}

fresh_disk() {
    stop_vm
    cp --sparse=always "$work/base.img" "$disk"
    start_vm
    wait_guest
    wait_blessed >/dev/null
    prepare_guest_repo
}

wait_rollback() {
    local want=$1 limit=${2:-2400} start=$SECONDS
    sleep 5
    until [ "$(running 2>/dev/null)" = "$want" ]; do
        [ $((SECONDS - start)) -lt "$limit" ] || { echo "never reached $want"; return 1; }
        sleep 5
    done
}

scenario_good() {
    note "a good update installs on a copy and boots"
    fresh_disk
    add_update hello-update 2 'echo installed > /etc/hello-update'
    local id
    id=$(guest bande-system prepare | tail -n 1)
    expect "running system untouched while prepared" "" "$(guest cat /etc/hello-update 2>/dev/null || true)"
    guest systemctl reboot || true
    sleep 5
    wait_rollback "/@system/$id"
    wait_blessed
    expect "update in the new version" installed "$(guest cat /etc/hello-update)"
    expect "counter removed" 1 "$(guest "ls /boot/efi/loader/entries | grep -c '^bande-2.conf$'")"
    add_update live-tool 1
    guest apt-get install -y -qq live-tool >/dev/null
    guest apt-get install -y -qq --reinstall live-tool >/dev/null
    expect "a live change keeps the updated version running" "/@system/$id" "$(running)"
}

scenario_panic() {
    note "an update whose boot cannot find its root falls back with nobody doing anything"
    fresh_disk
    add_update bad-kernel 2 'echo "root=UUID=00000000-0000-0000-0000-000000000000 rw console=ttyAMA0" > /etc/kernel/cmdline'
    guest bande-system prepare | tail -n 1
    guest systemctl reboot || true
    wait_rollback /@system/1
    wait_blessed
    expect "failed entry marked" 1 "$(guest "ls /boot/efi/loader/entries | grep -c '^bande-2+0-3.conf$'")"
    expect "tries it took" 3 "$(grep -ac 'ALERT!' "$work/serial.log")"
    expect "the desktop is told" 1 "$(guest 'wc -l < /run/bande/went-back')"
    expect "versions are published" 1 "$(guest 'grep -c running /run/bande/versions')"
}

scenario_login() {
    note "an update that boots but never shows a login window falls back"
    fresh_disk
    add_update bad-session 2 'touch /etc/test-login-broken'
    guest bande-system prepare | tail -n 1
    guest systemctl reboot || true
    wait_rollback /@system/1
    wait_blessed
    expect "failed entry marked" 1 "$(guest "ls /boot/efi/loader/entries | grep -c '^bande-2+0-3.conf$'")"
}

scenario_emergency() {
    note "an update that drops to emergency mode falls back"
    fresh_disk
    add_update bad-mount 2 'echo "UUID=00000000-0000-0000-0000-000000000000 /mnt ext4 defaults,x-systemd.device-timeout=5s 0 0" >> /etc/fstab'
    guest bande-system prepare | tail -n 1
    guest systemctl reboot || true
    wait_rollback /@system/1
    wait_blessed
    expect "failed entry marked" 1 "$(guest "ls /boot/efi/loader/entries | grep -c '^bande-2+0-3.conf$'")"
}

scenario_failed_install() {
    note "a failed install changes nothing"
    fresh_disk
    add_update bad-postinst 2 'exit 1'
    guest bande-system prepare >/dev/null 2>&1 && { echo "FAILED: prepare should fail"; fail=1; } || true
    expect "no extra version" 1 "$(guest 'mkdir -p /run/t; mount -o subvolid=5 $(findmnt -no SOURCE / | sed "s/\[.*//") /run/t; ls /run/t/@system | grep -c "^[0-9]*$"; umount /run/t')"
    expect "no extra entry" 1 "$(guest 'ls /boot/efi/loader/entries | wc -l')"
}

scenario_power_cut() {
    note "a power cut during the install changes nothing"
    fresh_disk
    add_update slow-update 2 'sleep 600'
    guest 'nohup bande-system prepare >/dev/null 2>&1 &' || true
    sleep 15
    stop_vm
    start_vm
    wait_guest
    wait_blessed >/dev/null
    expect "still the same version" /@system/1 "$(running)"
    expect "no new entry" 1 "$(guest 'ls /boot/efi/loader/entries | wc -l')"
    add_update fast-update 2 'true'
    guest "rm -f /srv/repo/slow-update-2.deb; cd /srv/repo && apt-ftparchive packages . > Packages && apt-get update -qq"
    local id
    id=$(guest bande-system prepare | tail -n 1)
    expect "unfinished version cleaned" 2 "$id"
    expect "versions on disk" 2 "$(guest bande-system list | wc -l)"
}

scenario_restore() {
    note "restore brings a version back and keeps the password changed since"
    fresh_disk
    add_update hello-update 2 'echo installed > /etc/hello-update'
    local id restored
    id=$(guest bande-system prepare | tail -n 1)
    guest systemctl reboot || true
    sleep 5
    wait_rollback "/@system/$id"
    wait_blessed >/dev/null
    guest 'echo tester:changed | chpasswd; useradd -m -G video second; mkdir -p /etc/NetworkManager/system-connections; echo wifi > /etc/NetworkManager/system-connections/home'
    guest 'echo kept > /home/tester/file'
    local password
    password=$(guest "grep ^tester: /etc/shadow | cut -d: -f2")
    restored=$(guest bande-system restore 1 | tail -n 1)
    guest systemctl reboot || true
    sleep 5
    wait_rollback "/@system/$restored"
    wait_blessed >/dev/null
    expect "system is the old one" "" "$(guest cat /etc/hello-update 2>/dev/null || true)"
    expect "changed password kept" "$password" "$(guest "grep ^tester: /etc/shadow | cut -d: -f2")"
    expect "new account kept" second "$(guest 'id -un second')"
    expect "group membership kept" 1 "$(guest 'id -nG second | grep -c video')"
    expect "wifi kept" wifi "$(guest cat /etc/NetworkManager/system-connections/home)"
    expect "home untouched" kept "$(guest cat /home/tester/file)"
    expect "first-boot marker gone" 0 "$(guest 'ls /.bande-first-boot 2>/dev/null | wc -l')"
}

scenario_units() {
    note "the services Settings starts prepare and restore"
    fresh_disk
    add_update hello-update 2 'echo installed > /etc/hello-update'
    guest systemctl start bande-system-prepare.service
    expect "the prepared update is published" 1 "$(guest "grep -c 'pending' /run/bande/versions")"
    guest systemctl start bande-system-restore@1.service
    expect "a restore replaces it" 0 "$(guest "cut -f3 /run/bande/versions | grep -c '^update$' || true")"
    expect "and is published as pending" 1 "$(guest "grep -c 'pending' /run/bande/versions")"
    guest 'apt-get update -qq; apt-get install -y -qq hello-update >/dev/null 2>&1'
    expect "a dpkg run leaves the pending restore" 1 "$(guest "grep -c 'pending' /run/bande/versions")"
}

scenario_reinstall() {
    note "a new tree adopted from outside it boots next and keeps accounts and Wi-Fi"
    fresh_disk
    guest 'mkdir -p /run/t; mount -o subvolid=5 "$(findmnt -no SOURCE / | sed "s/\[.*//")" /run/t
        btrfs -q subvolume snapshot /run/t/@system/1 /run/t/@system/7
        printf "created=%s\nwhy=reinstall\n" "$(date +%s)" > /run/t/@system/7.info
        echo tester:changed | chpasswd; useradd -m -G video second
        mkdir -p /etc/NetworkManager/system-connections; echo wifi > /etc/NetworkManager/system-connections/home
        R=/run/t/@system/7; mount --bind /boot/efi $R/boot/efi; for d in dev proc sys; do mount --bind /$d $R/$d; done
        chroot $R env BANDE_ESP=/boot/efi bande-system adopt 7
        for d in boot/efi dev proc sys; do umount $R/$d; done; umount /run/t; sync'
    local password
    password=$(guest "grep ^tester: /etc/shadow | cut -d: -f2")
    expect "it boots next" 1 "$(guest "ls /boot/efi/loader/entries | grep -c '^bande-2+3.conf$'")"
    guest systemctl reboot || true
    sleep 5
    wait_rollback /@system/7
    wait_blessed >/dev/null
    expect "password carried" "$password" "$(guest "grep ^tester: /etc/shadow | cut -d: -f2")"
    expect "account carried" second "$(guest 'id -un second')"
    expect "wifi carried" wifi "$(guest cat /etc/NetworkManager/system-connections/home)"
    expect "marked good" 1 "$(guest "ls /boot/efi/loader/entries | grep -c '^bande-2.conf$'")"
    expect "listed" 1 "$(guest "bande-system list | grep -c reinstall")"
}

scenario_live() {
    note "a terminal apt keeps a copy first; a bad live change falls back to the last system that booted"
    fresh_disk
    add_update live-tool 1
    guest apt-get install -y -qq live-tool >/dev/null
    expect "running stays" /@system/1 "$(running)"
    guest ls /boot/efi/loader/entries
    add_update live-break 1 'touch /etc/test-login-broken'
    guest apt-get install -y -qq live-break >/dev/null
    guest systemctl reboot || true
    wait_rollback /@system/2
    wait_blessed
    expect "the copy has no breakage" "" "$(guest cat /etc/test-login-broken 2>/dev/null || true)"
}

export LC_ALL=C.UTF-8
mkdir -p "$work"
build_base
[ $# -gt 0 ] || set -- good panic login emergency failed_install power_cut restore live units reinstall
for scenario in "$@"; do
    "scenario_$scenario"
done
stop_vm
[ "$fail" = 0 ] && echo ALL-OK || echo SOME-FAILED
exit "$fail"
