#!/bin/bash
set -euo pipefail

output=$1
image=$2
root=$3
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

image_partuuid=b4d6e1f2-7a53-4c8e-9f10-3d2c1b0a9e87
esp_mib=512
version=$(basename "$(find "$root/lib/modules" -mindepth 1 -maxdepth 1 | sort -V | tail -1)")
case "$(dpkg --print-architecture --root "$root" 2>/dev/null || cat "$root/var/lib/dpkg/arch")" in
*arm64*) loader=BOOTAA64.EFI; stub=systemd-bootaa64.efi ;;
*) loader=BOOTX64.EFI; stub=systemd-bootx64.efi ;;
esac

mkfs.vfat -C -F 32 -n BANDE-USB "$work/esp.img" $((esp_mib * 1024)) >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "$work/esp.img" ::/EFI ::/EFI/BOOT ::/loader ::/loader/entries ::/bande
mcopy -i "$work/esp.img" "$root/usr/lib/systemd/boot/efi/$stub" "::/EFI/BOOT/$loader"
mcopy -i "$work/esp.img" "$root/boot/vmlinuz-$version" ::/bande/linux
mcopy -i "$work/esp.img" "$root/boot/initrd.img-$version" ::/bande/initrd
printf 'timeout 0\n' > "$work/loader.conf"
cat > "$work/bande.conf" <<EOT
title Bande
linux /bande/linux
initrd /bande/initrd
options boot=bande-live bande.image=PARTUUID=$image_partuuid quiet
EOT
mcopy -i "$work/esp.img" "$work/loader.conf" ::/loader/loader.conf
mcopy -i "$work/esp.img" "$work/bande.conf" ::/loader/entries/bande.conf

image_mib=$(( ($(stat -c %s "$image") + 1048575) / 1048576 ))
rm -f "$output"
truncate -s $(( (1 + esp_mib + image_mib + 1) * 1048576 )) "$output"
sfdisk -q "$output" <<EOT
label: gpt
start=1MiB, size=${esp_mib}MiB, type=U, name=EFI
size=${image_mib}MiB, type=L, name=BANDE-RECOVERY, uuid=$image_partuuid
EOT
dd if="$work/esp.img" of="$output" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$image" of="$output" bs=1M seek=$((1 + esp_mib)) conv=notrunc,sparse status=none
