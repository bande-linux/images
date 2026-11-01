#!/bin/sh
set -eu
root=$1

echo bande > "$root/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tbande\n::1\tlocalhost ip6-localhost ip6-loopback\n' > "$root/etc/hosts"
cat > "$root/etc/fstab" <<EOT
UUID=$ROOT_UUID / ext4 rw,errors=remount-ro,x-systemd.growfs 0 1
UUID=$ESP_UUID /boot/efi vfat rw,umask=0077,nofail 0 2
EOT
cp -a --no-preserve=ownership "$ROOTFS/." "$root/"
chroot "$root" dpkg-divert --no-rename --package bande-images \
    --divert /usr/share/alsa/ucm2/conf.d/macaudio/cs42l84/Headphones.conf.asahi \
    --add /usr/share/alsa/ucm2/conf.d/macaudio/cs42l84/Headphones.conf
chroot "$root" systemctl enable NetworkManager systemd-resolved greetd bande-setup
chroot "$root" systemctl set-default graphical.target
chroot "$root" systemctl enable systemd-networkd
chroot "$root" systemctl disable systemd-networkd-wait-online

mkdir -p "$root/boot/efi/unboot" "$root/usr/lib/unboot" "$root/etc/kernel"
touch "$root/boot/efi/.builder"
[ -e "$WORK/unboot.bin" ] && cp "$WORK/unboot.bin" "$root/usr/lib/unboot/"
[ -e "$WORK/u-boot-nodtb.bin" ] && cp "$WORK/u-boot-nodtb.bin" "$root/usr/lib/unboot/"
echo "root=UUID=$ROOT_UUID rw" > "$root/etc/kernel/cmdline"
echo debian > "$root/etc/kernel/entry-token"

mount --bind "$root/boot/efi" "$root/boot/efi"
if [ "$BOOT_CHAIN" = uboot ]; then
    SYSTEMD_RELAX_ESP_CHECKS=1 chroot "$root" bootctl install --esp-path=/boot/efi \
        --no-variables --entry-token=literal:debian
else
    echo COMPRESS=gzip > "$root/etc/initramfs-tools/conf.d/unboot-direct"
fi

mkdir -p "$root/tmp/debs"
cp "$WORK"/debs/*.deb "$root/tmp/debs/"
mkdir -p "$root/tmp/desktop"
cp "$WORK"/desktop/*.deb "$root/tmp/desktop/"
SYSTEMD_RELAX_ESP_CHECKS=1 chroot "$root" sh -c 'apt-get install -y --no-install-recommends /tmp/debs/bande-scripts_*.deb /tmp/debs/bande-usb-gadget_*.deb && apt-get install -y --no-install-recommends /tmp/debs/linux-image-*.deb'
chroot "$root" sh -c 'apt-get install -y --no-install-recommends /tmp/desktop/*.deb'
rm -rf "$root/tmp/debs" "$root/tmp/desktop"
umount "$root/boot/efi"

if [ "$BOOT_CHAIN" = direct ] && [ -e "$root/usr/lib/unboot/unboot.bin" ]; then
    version=$(ls "$root/lib/modules")
    {
        cat "$root/usr/lib/unboot/unboot.bin" "$root/usr/lib/linux-image-$version"/apple/t8112-j473.dtb
        cat "$root/boot/vmlinuz-$version"
        cat "$root/boot/initrd.img-$version"
        echo "chosen.bootargs=$(cat "$root/etc/kernel/cmdline")"
    } > "$root/boot/efi/unboot/boot.bin"
fi

rm -f "$root/boot/efi/.builder" "$root/etc/machine-id" "$root/var/lib/dbus/machine-id"
touch "$root/etc/machine-id"
rm -f "$root"/etc/ssh/ssh_host_*
cat > "$root/etc/systemd/system/ssh-host-keys.service" <<'EOT'
[Unit]
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOT
chroot "$root" systemctl enable ssh-host-keys.service
