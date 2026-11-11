# Bande images

The Bande OS image: Debian 14 (forky) with the Bande desktop, as a read-only system image that serves
as the USB installer, the recovery environment and the source for reinstalling. `main` is the trunk.

| Path | What it is |
|---|---|
| `build.sh` | builds an image with mmdebstrap from the Debian release `SUITE` (default forky, with its -updates and -security) and that suite of the Bande APT archive; CI builds one per suite in the archive's `conf/suites`: `apple`, `generic-arm64` or `generic-amd64` |
| `customize.sh` | the mmdebstrap customize hook: installs the desktop, the kernel and the machine's packages |
| `mkusb.sh` | packs the generic targets as a bootable GPT disk image for a USB stick or a VM |
| `apple-parts.sh` | builds what the `apple` target takes from outside the archive: unboot, U-Boot, `bande-scripts`, `bande-nvram` |
| `installer-data.py` | writes `installer_data.json` for the Mac installer |
| `rootfs/`, `rootfs-apple/` | files copied into the system, on all targets and on the Mac |
| `rootfs/usr/libexec/bande-install` | installs and reinstalls: partitions, LUKS2, btrfs, boot entries |
| `rootfs/usr/libexec/bande-first-run` | the root steps of the first-run assistant, usable only until setup is finished |
| `mkroot.sh`, `rollback-test.sh` | lay a root out as btrfs system versions and prove rollback under QEMU, without LUKS |
| `vm.py`, `vm-test.py` | boot an image under QEMU and prove install and first start |
| `tether/` | boots the mini's current ext4 system over USB through the m1n1 proxy, for debugging |

## Building

    ./ci-setup.sh
    sudo ./build.sh generic-arm64 archive-key.asc out
    sudo ./vm-test.py arm64 out/bande-debian-forky-generic-arm64.img vm

`LOCAL_DEBS=<dir>` installs local packages over the archive's, to try a change before it is
published. The image's secrets are nil: an account, a password and Wi-Fi come from the first-run
assistant, on the machine.

## CI

`build.yml` runs on `v*` tags and on dispatch, on GitHub-hosted runners. It signs the Mac image's
`installer_data.json` with the archive key (secret `APT_SIGNING_KEY`, as in the apt repository);
that file lists the SHA-256 of every file in the image zip, and the installer refuses data
without a valid signature and any file whose digest differs.
