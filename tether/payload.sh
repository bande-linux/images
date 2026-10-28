#!/bin/sh
# Runs in debian:trixie. $1: image zip, $2: vendor firmware cpio, $3: setup dir, $4: plan, $5: output dir.
# Writes payload.cpio (the install payload) and, in image/, the kernel, initrd and device tree
# that boot.sh boots, so the installed modules always match the kernel.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
zip=$(realpath "$1") fw=$(realpath "$2") setup=$(realpath "$3") plan=$(realpath "$4") out=$(realpath "$5")
apt-get update -qq
apt-get install -y -qq --no-install-recommends unzip mtools dosfstools e2fsprogs zstd cpio gcc libc6-dev linux-libc-dev >/dev/null
w=$(mktemp -d)
cd "$w"
unzip -q "$zip"
gcc -O2 -static -o drmgrab "$here/drmgrab.c"
mkfs.vfat -C -F 32 -n EFI -i "$(. "$plan"; echo "$ESP_VOLUME_ID")" esp.img $((512 * 1024)) >/dev/null
mkdir -p espfw/vendorfw espfw/unbound/setup
cp "$fw" espfw/vendorfw/firmware.cpio
cp "$setup"/* espfw/unbound/setup/
mcopy -s -i esp.img esp/* espfw/vendorfw espfw/unbound ::/
printf '%s\n' "write drmgrab /usr/local/bin/drmgrab" "sif /usr/local/bin/drmgrab mode 0100755" |
    debugfs -w root.img -f - >/dev/null 2>&1
e2fsck -fn root.img >/dev/null
mkdir -p p/payload
zstd -T0 -10 -q esp.img -o p/payload/esp.img.zst
zstd -T0 -10 -q root.img -o p/payload/root.img.zst
cp "$plan" p/payload/plan
cp "$here/run" p/payload/run
chmod 755 p/payload/run
(cd p && find . | cpio -o -H newc -R 0:0 --quiet) > "$out/payload.cpio"
kver=$(basename esp/debian/*)
mkdir -p "$out/image"
cp "esp/debian/$kver/initrd.img-$kver" "$out/image/initrd.img"
cp "esp/debian/$kver/linux" "$out/image/Image.gz"
debugfs -R "dump /usr/lib/linux-image-$kver/apple/t8112-j473.dtb $out/image/t8112-j473.dtb" root.img >/dev/null 2>&1
[ -s "$out/image/t8112-j473.dtb" ]
rm -rf "$w"
