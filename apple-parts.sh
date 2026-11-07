#!/bin/bash
set -euo pipefail
parts=$(realpath "$1")
out=$(realpath -m "$2")
mkdir -p "$out/debs"
sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    build-essential debhelper dpkg-dev gcc-aarch64-linux-gnu bison flex libssl-dev libgnutls28-dev \
    python3-venv python3-dev swig bc
for source in system-scripts nvram; do
    (cd "$parts/$source" && dpkg-buildpackage -us -uc -b)
done
cp "$parts"/*.deb "$out/debs/"
make -C "$parts/bootloader" -j"$(nproc)" ARCH= CHAINLOADING=1
cp "$parts/bootloader/build/unboot.bin" "$out/"
python3 -m venv "$parts/venv"
"$parts/venv/bin/pip" install -q setuptools pyelftools
PATH=$parts/venv/bin:$PATH make -C "$parts/u-boot" apple_m1_defconfig
PATH=$parts/venv/bin:$PATH make -C "$parts/u-boot" -j"$(nproc)"
cp "$parts/u-boot/u-boot-nodtb.bin" "$out/"
