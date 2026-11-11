#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <apple|generic-arm64|generic-amd64> <archive key> <output dir>"
    exit 1
}

[ $# -eq 3 ] || usage
target=$1
key=$(realpath "$2")
out=$(realpath -m "$3")
here=$(cd "$(dirname "$0")" && pwd)

: "${SUITE:=forky}"
: "${MIRROR:=http://deb.debian.org/debian}"
: "${ARCHIVE:=https://bande-linux.github.io/apt}"
: "${LOCAL_DEBS:=}"
: "${UNBOOT:=}"
: "${U_BOOT:=}"
: "${ESP_VOLUME_ID:=0x3c2e1a9b}"
: "${SOURCE_DATE_EPOCH:=$(git -C "$here" log -1 --format=%ct)}"
export SOURCE_DATE_EPOCH

case "$target" in
apple)
    arch=arm64
    extra=bande-system,bande-os-apple,bande-scripts,bande-usb-gadget,bande-nvram,bande-bless,asahi-platform-audio
    [ -n "$UNBOOT" ] && [ -n "$U_BOOT" ] && [ -n "$LOCAL_DEBS" ] || {
        echo "apple needs UNBOOT, U_BOOT and LOCAL_DEBS with the bande-scripts and nvram packages"
        exit 1
    }
    ;;
generic-arm64)
    arch=arm64
    extra=bande-system,linux-image-arm64,firmware-linux-free,firmware-misc-nonfree,firmware-realtek,firmware-iwlwifi,firmware-atheros,firmware-brcm80211,firmware-mediatek
    ;;
generic-amd64)
    arch=amd64
    extra=bande-system,linux-image-amd64,firmware-linux-free,firmware-misc-nonfree,firmware-realtek,firmware-iwlwifi,firmware-atheros,firmware-brcm80211,firmware-mediatek,firmware-amd-graphics,firmware-intel-graphics,firmware-sof-signed,amd64-microcode,intel-microcode
    ;;
*) usage ;;
esac

name=bande-debian-$SUITE-$target
work=$(mktemp -d -p /var/tmp)
cleanup() {
    "$here/rootfs/usr/libexec/bande-install" release "$work/target" 2>/dev/null || true
    [ -z "${loop:-}" ] || losetup -d "$loop" 2>/dev/null || true
    rm -rf --one-file-system "$work"
}
trap cleanup EXIT
root=$work/root
mkdir -p "$out" "$work/local"
[ -z "$LOCAL_DEBS" ] || cp "$LOCAL_DEBS"/*.deb "$work/local/"
[ -z "$UNBOOT" ] || cp "$UNBOOT" "$work/unboot.bin"
[ -z "$U_BOOT" ] || cp "$U_BOOT" "$work/u-boot-nodtb.bin"
gpg --batch --quiet --dearmor < "$key" > "$work/archive.gpg"

packages="systemd-sysv,udev,dbus,kmod,initramfs-tools,busybox,cpio,zstd,
systemd-boot,systemd-boot-efi,systemd-resolved,systemd-oomd,systemd-zram-generator,systemd-coredump,
btrfs-progs,linux-base,cryptsetup,cryptsetup-bin,cryptsetup-initramfs,libx11-data,squashfs-tools,dosfstools,e2fsprogs,fdisk,parted,polkitd,pkexec,
iproute2,iputils-ping,ca-certificates,less,nano,sudo,apt-utils,locales,console-setup,tzdata,
network-manager,wpasupplicant,wireless-regdb,
libpam-systemd,dbus-user-session,mesa-vulkan-drivers,libgbm1,vulkan-tools,
pipewire,pipewire-pulse,pipewire-alsa,wireplumber,rtkit,alsa-utils,
bluez,libspa-0.2-bluetooth,packagekit,fonts-noto-core,accountsservice,
fuse3,cifs-utils,smbclient,sshfs,davfs2,go-mtpfs,gphotofs,libmtp-common"

env -u UNBOOT -u U_BOOT -u SOURCE -u TARGET -u CONFIG -u DTBS WORK="$work" HERE="$here" IMAGE_TARGET="$target" ARCHIVE="$ARCHIVE" EXTRA="$extra" \
mmdebstrap --variant=minbase --arch="$arch" --mode=root --format=directory \
    --components=main,non-free-firmware \
    --include="$(echo "$packages" | tr -d '\n')" \
    --customize-hook="$here/customize.sh \"\$1\"" \
    "$SUITE" "$root" "deb $MIRROR $SUITE main non-free-firmware" \
    "deb $MIRROR $SUITE-updates main non-free-firmware" \
    "deb http://security.debian.org/debian-security $SUITE-security main non-free-firmware"

recovery=$work/recovery.img
mksquashfs "$root" "$recovery" -quiet -no-progress -comp zstd -Xcompression-level 15 \
    -reproducible
truncate -s %4096 "$recovery"
recovery_size=$(stat -c %s "$recovery")
[ "$recovery_size" -le $((6 * 1024 * 1024 * 1024)) ] || {
    echo "The system image is larger than the 6 GB recovery partition."
    exit 1
}

if [ "$target" = apple ]; then
    root_size=$(( $(du -sm "$root" | cut -f1) * 13 / 10 + 1024 ))
    truncate -s "${root_size}M" "$work/root.img"
    mkdir -p "$work/pkg/esp" "$work/target"
    loop=$(losetup --find --show "$work/root.img")
    env -u UNBOOT -u U_BOOT ESP_DIR=$work/pkg/esp ESP_UUID=$(echo "${ESP_VOLUME_ID#0x}" | tr a-f A-F | sed "s/^\(....\)/\1-/") RECOVERY_PARTUUID=@RECOVERY_PARTUUID@ "$here/rootfs/usr/libexec/bande-install" image "$loop" "$recovery" "$work/target"
    losetup -d "$loop"
    loop=
    rm -f "$work/pkg/esp/loader/random-seed"
    [ -s "$work/pkg/esp/unboot/boot.bin" ] || {
        echo "No unboot/boot.bin on the ESP: the installer chainloads it, so the image cannot boot."
        exit 1
    }
    mv "$recovery" "$work/pkg/recovery.img"
    mv "$work/root.img" "$work/pkg/root.img"
    (cd "$work/pkg" && find esp recovery.img root.img -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + &&
        rm -f "$out/$name.zip" && find esp recovery.img root.img | LC_ALL=C sort | zip -q -X -1 -@ "$out/$name.zip")
    python3 "$here/installer-data.py" "$name" "$recovery_size" "$((root_size * 1024 * 1024))" "$ESP_VOLUME_ID" \
        "$work/pkg" > "$out/installer_data.json"
else
    "$here/mkusb.sh" "$out/$name.img" "$recovery" "$root"
fi

ls -l "$out"
