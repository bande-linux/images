# Bande images

The Mac mini M2 OS image: a Debian root filesystem with the Bande desktop, packed for the
installer, and the tether initramfs. `main` is the trunk.

| Path | What it is |
|---|---|
| `build.sh` | builds the image with mmdebstrap from a kernel deb, the bande-scripts debs and the desktop debs |
| `customize.sh` | the mmdebstrap customize hook: hostname, fstab, services, the boot chain (`uboot` or `direct`) |
| `fetch-desktop.sh` | fetches and checks the desktop packages from the Bande APT archive |
| `installer-data.py` | writes `installer_data.json` for the installer |
| `rootfs/` | files copied into the root filesystem |
| `test-root.sh`, `vm-test.sh` | boot the root filesystem under QEMU/KVM |
| `tether/` | installs, removes and boots the image on the mini over USB with a tether initramfs |

## CI

`build.yml` runs on `v*` tags and on dispatch. It checks out `bande-linux/u-boot` at `main`
(upstream plus the unboot commits) and `bande-linux/bootloader`.

**Needs port (not needed for the launch).** `build.yml` still builds the kernel from the legacy
`bande-linux/linux` tree (input `kernel-ref`, default `bande-hw/integration`) and runs the image job
on the self-hosted `bande-kvm` runner. The kernel now comes from the `kernel` repo and is published
as `linux-image-apple-arm64-16k` (split into `-image`, `-binary`, `-modules` and `-base` debs) in the
Bande archive's `apple` component. The port: fetch those packages from the archive the way
`fetch-desktop.sh` fetches the desktop, let `build.sh` take more than one kernel deb, and move the
image job to a GitHub-hosted runner.
