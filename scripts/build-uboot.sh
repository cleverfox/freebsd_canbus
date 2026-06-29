#!/bin/sh
#
# build-uboot.sh -- build mainline U-Boot for the Pine64 SOQuartz (RK3566)
# Model A directly (bypassing the FreeBSD u-boot port, whose toolchain/texinfo
# deps hit a ports perl5 issue on this host).
#
# Prereqs (binary pkgs): aarch64-none-elf-gcc, gmake, bison, flex, gawk, gsed,
# swig, python3, dtc, rkbin (provides the RK3566 DDR TPL + RK3568 TF-A BL31).
#
# Produces idbloader.img + u-boot.itb in $UBUILD, using the
# soquartz-model-a-rk3566_defconfig so U-Boot drives the real SOQuartz Model A
# hardware (the quartz64-a build resets at GMAC/Net init on this board).
set -eu

: "${UBUILD:=$HOME/ubuild}"
: "${RKBIN:=/usr/local/share/rkbin/rk35}"
: "${BL31:=$RKBIN/rk3568_bl31_v1.45.elf}"
: "${TPL:=$RKBIN/rk3566_ddr_1056MHz_v1.23.bin}"
DEFCONFIG=soquartz-model-a-rk3566_defconfig
JOBS=$(sysctl -n hw.ncpu)

# U-Boot scripts assume GNU sed/awk; shim them ahead of base versions.
mkdir -p "$HOME/gnubin"
ln -sf /usr/local/bin/gsed "$HOME/gnubin/sed"
ln -sf /usr/local/bin/gawk "$HOME/gnubin/awk"
export PATH="$HOME/gnubin:/usr/local/bin:$PATH"
export CROSS_COMPILE=aarch64-none-elf-

cd "$UBUILD"
gmake mrproper
gmake "$DEFCONFIG"

# NOTE: do NOT inject CONFIG_PREBOOT/CONFIG_BOOTCOMMAND here. Doing that and
# re-running olddefconfig regressed bootefi's EFI-disk SD handling (bootefi
# re-probe -> -110), while fatload kept working. Build the plain upstream
# defconfig, which is the configuration that booted reliably via
# `mmc dev 1; fatload mmc 1:1 ... BOOTAA64.EFI; bootefi ...`. Autoboot
# reliability will be revisited separately, without touching the EFI config.
gmake -j"$JOBS" BL31="$BL31" ROCKCHIP_TPL="$TPL"

echo "=== artifacts ==="
ls -l "$UBUILD/idbloader.img" "$UBUILD/u-boot.itb"
