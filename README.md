# Bande images

The Mac mini M2 OS image: a Debian root filesystem with the Bande desktop, packed for the
installer, and the tether initramfs. `main` is the trunk.

| Path | What it is |
|---|---|
| `build.sh` | builds the image with mmdebstrap from a kernel deb, the bande-scripts debs and the desktop debs |
| `customize.sh` | the mmdebstrap customize hook: hostname, fstab, services, the boot chain (`uboot` or `direct`) |
| `fetch-desktop.sh` | fetches and checks the desktop packages from the Bande APT archive, and the bande-linux/apps packages `bande-desktop` recommends (it fails if one is missing unless `ALLOW_MISSING_APPS=1`) |
| `installer-data.py` | writes `installer_data.json` for the installer |
| `rootfs/` | files copied into the root filesystem |
| `test-root.sh`, `vm-test.sh` | boot the root filesystem under QEMU/KVM |
| `tether/` | installs, removes and boots the image on the mini over USB with a tether initramfs |

## CI

`build.yml` runs on `v*` tags and on dispatch. It checks out `bande-linux/u-boot` at `main`
(upstream plus the unboot commits) and `bande-linux/bootloader`.

**Broken until ported.** `build.yml` still builds the kernel from the legacy `bande-linux/linux`
tree and runs the image job on a self-hosted runner that no longer exists. The port: take the
kernel's `linux-image-apple-arm64-16k` packages from the archive's `apple` component (published
once Debian testing has 7.3), the way `fetch-desktop.sh` fetches the desktop, let `build.sh` take
more than one kernel deb, and run the image job on a GitHub-hosted runner.
