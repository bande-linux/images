#!/bin/sh
# Runs in debian:testing. $1: image zip, $2: vendor firmware cpio, $3: setup dir, $4: plan, $5: output dir.
# Writes payload.cpio (the install payload) and, in image/, the kernel, initrd and device tree
# that boot.sh boots, so the installed modules always match the kernel.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
zip=$(realpath "$1") fw=$(realpath "$2") setup=$(realpath "$3") plan=$(realpath "$4") out=$(realpath "$5")
# Without a password the user can log in with a key but never use sudo, and root stays locked.
[ ! -s "$setup/user" ] || [ -s "$setup/password" ] || { echo "$setup has a user but no password" >&2; exit 1; }
apt-get update -qq
apt-get install -y -qq --no-install-recommends unzip mtools dosfstools zstd cpio gcc libc6-dev linux-libc-dev >/dev/null
w=$(mktemp -d)
cd "$w"
unzip -q "$zip"
gcc -O2 -static -o drmgrab "$here/drmgrab.c"
mkfs.vfat -C -F 32 -S "$(. "$plan"; echo "$SECTOR_SIZE")" -n EFI -i "$(. "$plan"; echo "$ESP_VOLUME_ID")" esp.img $((512 * 1024)) >/dev/null
mkdir -p espfw/vendorfw espfw/bande/setup
cp "$fw" espfw/vendorfw/firmware.cpio
cp "$setup"/* espfw/bande/setup/
cp drmgrab espfw/bande/drmgrab
mcopy -s -i esp.img esp/* espfw/vendorfw espfw/bande ::/
mkdir -p p/payload
zstd -T0 -10 -q esp.img -o p/payload/esp.img.zst
zstd -T0 -10 -q root.img -o p/payload/root.img.zst
cp "$plan" p/payload/plan
cp "$here/run" p/payload/run
chmod 755 p/payload/run
(cd p && find . | cpio -o -H newc -R 0:0 --quiet) > "$out/payload.cpio"
entry=esp/loader/entries/bande-1.conf
mkdir -p "$out/image"
cp "esp$(sed -n 's/^initrd //p' "$entry")" "$out/image/initrd.img"
cp "esp$(sed -n 's/^linux //p' "$entry")" "$out/image/Image.gz"
cp esp/bande/t8112-j473.dtb "$out/image/t8112-j473.dtb"
[ -s "$out/image/t8112-j473.dtb" ]
rm -rf "$w"
