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
chroot "$troot" ssh-keygen -q -t ed25519 -N '' -C unbound-test -f /root/test-key
echo vkms > "$troot/etc/modules-load.d/unbound-test.conf"
cat > "$troot/usr/local/sbin/unbound-test" <<'EOT'
#!/bin/sh
for i in $(seq 90); do pgrep -u tester unbound-composi >/dev/null && break; sleep 1; done
sleep 3
line() { echo "UNBOUND-TEST-$1: $(sh -c "$2" 2>&1 | tr -s ' ' | tr '\n' ';')"; }
line FW 'cat /lib/firmware/vendor/unbound-test.bin'
line NET 'nmcli -t -f TYPE,STATE device'
line USER 'id -nG tester'
line SSH 'ssh -i /root/test-key -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=ERROR tester@127.0.0.1 echo key-login'
line SSHD 'sshd -T | grep -E "^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) "'
line WIFI 'nmcli -t -f NAME,TYPE connection show'
line SETUP 'ls -A /boot/efi/unbound'
line SESSION 'loginctl list-sessions --no-legend'
line COMPOSITOR 'pgrep -u tester -a unbound-composi'
line VULKAN 'vulkaninfo --summary | grep -E "deviceName|driverInfo"'
line MESA 'dpkg-query -W -f "\${Version}" mesa-vulkan-drivers'
echo UNBOUND-TEST-DONE
EOT
chmod 755 "$troot/usr/local/sbin/unbound-test"
cat > "$troot/etc/systemd/system/unbound-test.service" <<'EOT'
[Unit]
After=graphical.target

[Service]
Type=oneshot
StandardOutput=tty
TTYPath=/dev/ttyAMA0
ExecStart=/usr/local/sbin/unbound-test

[Install]
WantedBy=graphical.target
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
mkdir -p "$WORK/espfw/vendorfw" "$WORK/espfw/unbound/setup"
printf tester > "$WORK/espfw/unbound/setup/user"
printf 'test password' > "$WORK/espfw/unbound/setup/password"
cp "$troot/root/test-key.pub" "$WORK/espfw/unbound/setup/authorized_keys"
printf 'Unbound Test' > "$WORK/espfw/unbound/setup/wifi-ssid"
printf 'unbound test passphrase' > "$WORK/espfw/unbound/setup/wifi-psk"
(cd "$WORK/fw" && find vendorfw | cpio --quiet -o -H newc) > "$WORK/espfw/vendorfw/firmware.cpio"

rm -f "$WORK/esp.img"
mkfs.vfat -C -F 32 -i "$(echo "$ESP_VOLUME_ID" | sed 's/^0x//')" "$WORK/esp.img" $((512 * 1024)) >/dev/null
mcopy -s -i "$WORK/esp.img" "$esp"/* "$WORK/espfw/vendorfw" "$WORK/espfw/unbound" ::/

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
