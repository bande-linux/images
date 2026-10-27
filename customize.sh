#!/bin/sh
set -eu
root=$1

echo unbound > "$root/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tunbound\n::1\tlocalhost ip6-localhost ip6-loopback\n' > "$root/etc/hosts"
cat > "$root/etc/fstab" <<EOT
UUID=$ROOT_UUID / ext4 rw,errors=remount-ro,x-systemd.growfs 0 1
UUID=$ESP_UUID /boot/efi vfat rw,umask=0077,nofail 0 2
EOT
mkdir -p "$root/etc/systemd/network"
cat > "$root/etc/systemd/network/20-wired.network" <<'EOT'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOT
chroot "$root" systemctl enable systemd-networkd systemd-resolved

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
SYSTEMD_RELAX_ESP_CHECKS=1 chroot "$root" sh -c 'apt-get install -y --no-install-recommends /tmp/debs/unbound-scripts_*.deb && apt-get install -y --no-install-recommends /tmp/debs/linux-image-*.deb'
rm -rf "$root/tmp/debs"
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
