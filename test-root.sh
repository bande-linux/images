#!/bin/sh
set -eu

root=$1
esp=$2
out=$3/test
troot=$WORK/test-root
: "${ESP_PARTUUID:=6f1e2d3c-4b5a-4968-8776-5a4b3c2d1e0f}"
: "${TEST_KERNEL:=unbound}"

mkdir -p "$out"
cp -a "$root" "$troot"
trap 'umount -R "$troot/proc" "$troot/sys" "$troot/dev" 2>/dev/null || true' EXIT
mount -t proc proc "$troot/proc"
mount -t sysfs sys "$troot/sys"
mount --rbind /dev "$troot/dev"
resolv=$(readlink "$troot/etc/resolv.conf" || true)
rm -f "$troot/etc/resolv.conf"
cp /etc/resolv.conf "$troot/etc/resolv.conf"
if [ "$TEST_KERNEL" = debian ]; then
    chroot "$troot" sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends linux-image-arm64 && apt-get clean'
fi
rm -rf "$troot"/var/lib/apt/lists/*
[ -n "$resolv" ] && ln -sf "$resolv" "$troot/etc/resolv.conf"
cat > "$troot/etc/systemd/system/unbound-test.service" <<'EOT'
[Unit]
After=multi-user.target

[Service]
Type=oneshot
StandardOutput=tty
TTYPath=/dev/ttyAMA0
ExecStart=/bin/sh -c 'echo "UNBOUND-TEST-FW: $(cat /lib/firmware/vendor/unbound-test.bin 2>&1)"; echo "UNBOUND-TEST-NET: $(networkctl list --no-legend 2>&1 | tr -s " " | tr "\\n" ";")"; echo UNBOUND-TEST-DONE'

[Install]
WantedBy=multi-user.target
EOT
chroot "$troot" systemctl enable unbound-test.service
umount "$troot/proc"
umount "$troot/sys"
umount -R "$troot/dev"
trap - EXIT

if [ "$TEST_KERNEL" = debian ]; then
    version=$(ls "$troot/lib/modules" | grep -- '-arm64$')
else
    version=$(ls "$troot/lib/modules" | grep -v -- '-arm64$' | head -1)
fi
cp "$troot/boot/vmlinuz-$version" "$out/vmlinuz"
cp "$troot/boot/initrd.img-$version" "$out/initrd.img"

size=$(du -sm "$troot" | cut -f1)
mkfs.ext4 -q -L root -U "$ROOT_UUID" -d "$troot" "$WORK/test-root.img" "$((size * 13 / 10 + 256))M"

mkdir -p "$WORK/fw/vendorfw"
echo unbound-test-firmware > "$WORK/fw/vendorfw/unbound-test.bin"
echo "unbound-test.bin" > "$WORK/fw/vendorfw/.vendorfw.manifest"
mkdir -p "$WORK/espfw/vendorfw"
(cd "$WORK/fw" && find vendorfw | cpio --quiet -o -H newc) > "$WORK/espfw/vendorfw/firmware.cpio"

rm -f "$WORK/esp.img"
mkfs.vfat -C -F 32 -i "$(echo "$ESP_VOLUME_ID" | sed 's/^0x//')" "$WORK/esp.img" $((512 * 1024)) >/dev/null
mcopy -s -i "$WORK/esp.img" "$esp"/* "$WORK/espfw/vendorfw" ::/

esp_sectors=$(( $(stat -c %s "$WORK/esp.img") / 512 ))
root_sectors=$(( $(stat -c %s "$WORK/test-root.img") / 512 ))
disk=$out/disk.img
rm -f "$disk"
truncate -s $(( (2048 + esp_sectors + root_sectors + 2048) * 512 )) "$disk"
sfdisk -q "$disk" <<EOT
label: gpt
start=2048, size=$esp_sectors, type=U, uuid=$ESP_PARTUUID
start=$((2048 + esp_sectors)), size=$root_sectors, type=L
EOT
dd if="$WORK/esp.img" of="$disk" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$WORK/test-root.img" of="$disk" bs=512 seek=$((2048 + esp_sectors)) conv=notrunc,sparse status=none
echo "$ESP_PARTUUID" > "$out/esp-partuuid"
echo "$ROOT_UUID" > "$out/root-uuid"
