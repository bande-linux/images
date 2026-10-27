#!/bin/sh
set -eu

usage() {
    echo "Usage: $0 <linux-image.deb> <unbound-scripts.deb> <output dir>"
    exit 1
}

[ $# -eq 3 ] || usage
kernel_deb=$(realpath "$1")
scripts_deb=$(realpath "$2")
out=$(realpath "$3")
here=$(cd "$(dirname "$0")" && pwd)

: "${SUITE:=trixie}"
: "${MIRROR:=http://deb.debian.org/debian}"
: "${BOOT_CHAIN:=uboot}"
: "${NAME:=unbound-debian-13-server}"
: "${ROOT_UUID:=8a0b3f4e-6c1d-4e55-9b0a-2d7f1c3e5a61}"
: "${ESP_VOLUME_ID:=0x3c2e1a9b}"
: "${UNBOOT:=}"
: "${U_BOOT:=}"
: "${TEST_ROOT:=}"
: "${SOURCE_DATE_EPOCH:=$(git -C "$here" log -1 --format=%ct)}"
export SOURCE_DATE_EPOCH

case "$BOOT_CHAIN" in
uboot|direct) ;;
*) echo "BOOT_CHAIN must be uboot or direct."; exit 1 ;;
esac

work=$(mktemp -d)
trap 'umount -R "$work/root" 2>/dev/null || true; rm -rf "$work"' EXIT
root=$work/root
mkdir -p "$out" "$work/debs"
cp "$kernel_deb" "$scripts_deb" "$work/debs/"
[ -n "$UNBOOT" ] && cp "$UNBOOT" "$work/unboot.bin"
[ -n "$U_BOOT" ] && cp "$U_BOOT" "$work/u-boot-nodtb.bin"

esp_uuid=$(echo "$ESP_VOLUME_ID" | sed 's/^0x//' | tr a-f A-F | sed 's/^\(....\)/\1-/')

packages="systemd-sysv,udev,dbus,kmod,initramfs-tools,busybox,cpio,zstd,e2fsprogs,dosfstools,
openssh-server,systemd-resolved,iproute2,iputils-ping,ca-certificates,less,nano,sudo,apt-utils"
[ "$BOOT_CHAIN" = uboot ] && packages="$packages,systemd-boot,systemd-boot-efi"

WORK=$work BOOT_CHAIN=$BOOT_CHAIN ROOT_UUID=$ROOT_UUID ESP_UUID=$esp_uuid \
mmdebstrap --variant=minbase --arch=arm64 --mode=root --format=directory \
    --components=main,non-free-firmware \
    --include="$(echo "$packages" | tr -d '\n')" \
    --customize-hook="$here/customize.sh \"\$1\"" \
    "$SUITE" "$root" "deb $MIRROR $SUITE main non-free-firmware" \
    "deb $MIRROR $SUITE-updates main non-free-firmware" \
    "deb http://security.debian.org/debian-security $SUITE-security main non-free-firmware"

mkdir -p "$work/pkg"
mv "$root/boot/efi" "$work/pkg/esp"
rm -f "$work/pkg/esp/loader/random-seed"
mkdir "$root/boot/efi"

mkroot() {
    size=$(du -sm "$1" | cut -f1)
    size=$(( (size * 13 / 10 + 256) / 4 * 4 ))
    rm -f "$2"
    E2FSPROGS_FAKE_TIME=$SOURCE_DATE_EPOCH mkfs.ext4 -q -L root -U "$ROOT_UUID" \
        -E hash_seed="$ROOT_UUID",root_owner=0:0 -d "$1" "$2" "${size}M"
}

mkroot "$root" "$work/pkg/root.img"
root_size=$(stat -c %s "$work/pkg/root.img")

(cd "$work/pkg" && find esp root.img -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + &&
    rm -f "$out/$NAME.zip" && find esp root.img | LC_ALL=C sort | zip -q -X -1 -@ "$out/$NAME.zip")

python3 "$here/installer-data.py" "$NAME" "$root_size" "$ESP_VOLUME_ID" > "$out/installer_data.json"

if [ -n "$TEST_ROOT" ]; then
    WORK=$work ROOT_UUID=$ROOT_UUID ESP_VOLUME_ID=$ESP_VOLUME_ID "$here/test-root.sh" "$root" "$work/pkg/esp" "$out"
fi

ls -l "$out"
