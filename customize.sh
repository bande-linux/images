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
    # unboot decompresses gzip but not zstd, and an uncompressed cpio would end its payload list.
    echo COMPRESS=gzip > "$root/etc/initramfs-tools/conf.d/unboot-direct"
    # update-unboot builds the u-boot chain; with no systemd-boot on the ESP that image cannot boot.
    echo UNBOOT_UPDATE_DISABLED=1 > "$root/etc/default/update-unboot"
    mkdir -p "$root/etc/initramfs/post-update.d"
    cat > "$root/etc/initramfs/post-update.d/zz-unboot-direct" <<'EOT'
#!/bin/sh
# Rebuild the ESP's unboot/boot.bin for the direct chain: unboot, the J473
# devicetree, the gzip kernel, the gzip initramfs and the command line.
set -e
version=$1
initrd=${2:-/boot/initrd.img-$version}
bootloader=/usr/lib/unboot/unboot.bin
kernel=/boot/vmlinuz-$version
dtb=/usr/lib/linux-image-$version/apple/t8112-j473.dtb

[ -e "$bootloader" ] || exit 0
[ "$version" = "$(ls /lib/modules | sort -V | tail -n 1)" ] || exit 0

if [ "$(od -An -tx1 -N2 "$initrd" | tr -d ' \n')" != 1f8b ]; then
    echo "zz-unboot-direct: $initrd is not gzip, unboot cannot load it" >&2
    exit 1
fi

. /usr/share/bande-scripts/functions.sh
mount_sys_esp /run/.system-efi
target=/run/.system-efi/unboot/boot.bin
mkdir -p "${target%/*}"
{
    cat "$bootloader" "$dtb"
    if [ "$(head -c 8 "$kernel" | tail -c 4)" = zimg ]; then
        # EFI zboot: unboot needs the compressed Image inside the PE wrapper.
        case "$(head -c 28 "$kernel" | tail -c 4)" in
        gzip|xz) ;;
        *) echo "zz-unboot-direct: $kernel is not gzip or xz zboot" >&2; exit 1 ;;
        esac
        offset=$(od -An -tu4 -j8 -N4 "$kernel" | tr -d ' ')
        size=$(od -An -tu4 -j12 -N4 "$kernel" | tr -d ' ')
        tail -c +$((offset + 1)) "$kernel" | head -c "$size"
    elif [ "$(od -An -tx1 -N2 "$kernel" | tr -d ' \n')" = 1f8b ]; then
        cat "$kernel"
    else
        # An uncompressed Image would end unboot's payload list before the initramfs.
        gzip -n -c "$kernel"
    fi
    cat "$initrd"
    echo "chosen.bootargs=$(cat /etc/kernel/cmdline)"
} > "$target.new"
mv -f "$target.new" "$target"
umount /run/.system-efi
echo "zz-unboot-direct: $target updated for $version"
EOT
    chmod 755 "$root/etc/initramfs/post-update.d/zz-unboot-direct"
fi

mkdir -p "$root/tmp/debs"
cp "$WORK"/debs/*.deb "$root/tmp/debs/"
mkdir -p "$root/tmp/desktop"
cp "$WORK"/desktop/*.deb "$root/tmp/desktop/"
SYSTEMD_RELAX_ESP_CHECKS=1 chroot "$root" sh -c 'apt-get install -y --no-install-recommends /tmp/debs/bande-scripts_*.deb /tmp/debs/bande-usb-gadget_*.deb && apt-get install -y --no-install-recommends /tmp/debs/linux-image-*.deb'
chroot "$root" sh -c 'apt-get install -y --no-install-recommends /tmp/desktop/*.deb'
rm -rf "$root/tmp/debs" "$root/tmp/desktop"
umount "$root/boot/efi"

if [ ! -s "$root/boot/efi/unboot/boot.bin" ]; then
    echo "No unboot/boot.bin on the ESP: the installer chainloads it, so the image cannot boot."
    exit 1
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
