#!/bin/sh
#
# build-image-complete.sh -- runs ON the FreeBSD/amd64 build host. Produces the
# complete SOQuartz microSD image with SocketCAN + the mcp2515(4) driver baked
# in. Run it from this repo's checkout on the build host:
#
#     sh scripts/build-image-complete.sh
#
# Expects (see README.md "Build host"):
#   ~/src   = cleverfox/freebsd-src @ canbus, with patches/*.patch applied
#   ~/obj   = MAKEOBJDIRPREFIX (buildworld already run once)
#   U-Boot toolchain + deps installed as binary pkgs (see README.md)
#
# Produces:
#   - U-Boot (soquartz-model-a defconfig)
#   - GENERIC kernel (incl. the rk_spi fix) + all modules (mcp2515.ko, can.ko)
#   - rootfs: passwordless root, loader.conf autoloads can + mcp2515 and applies
#     the CAN overlay (compiled into /boot/dtb/overlays); spigen tool; slcand
#   - ~/soquartz-freebsd-arm64.img(.zst) + sha256
#
# Workdirs (~/uboot, ~/ubuild, ~/rootfs) are created under $HOME.
set -eu

SELF=$(cd "$(dirname "$0")" && pwd)        # <repo>/scripts
REPO=$(cd "$SELF/.." && pwd)               # <repo>
JOBS=$(sysctl -n hw.ncpu)
MK="env MAKEOBJDIRPREFIX=$HOME/obj __MAKE_CONF=/dev/null SRCCONF=/dev/null"

# repo-relative inputs consumed by mk-image.sh. Defaults bake in the MCP2515
# (classic CAN) overlay; for an MCP2518FD (CAN FD) module run instead:
#   env CAN_DRIVER=mcp251xfd \
#       MCP2515_OVERLAY=$REPO/overlays/rk3566-soquartz-mcp2518fd-can.dtso \
#       sh scripts/build-image-complete.sh
export MCP2515_OVERLAY="${MCP2515_OVERLAY:-$REPO/overlays/rk3566-soquartz-mcp2515-can.dtso}"
export MCP2515_SRC="${MCP2515_SRC:-$REPO/tools/mcp2515/mcp2515_spigen.c}"
export CAN_DRIVER="${CAN_DRIVER:-mcp2515}"

echo "=== [1/4] build SOQuartz U-Boot ==="
sh "$SELF/build-uboot.sh" 2>&1 | tail -3
mkdir -p ~/uboot && cp ~/ubuild/idbloader.img ~/ubuild/u-boot.itb ~/uboot/
ls -l ~/uboot

echo "=== [2/4] buildkernel GENERIC (rk_spi fix + all modules incl mcp2515) ==="
cd ~/src
$MK make -j"$JOBS" TARGET=arm64 TARGET_ARCH=aarch64 buildkernel KERNCONF=GENERIC 2>&1 | tail -4

echo "=== [3/4] assemble image (driver + overlay baked in) ==="
sh "$SELF/mk-image.sh" 2>&1 | tail -18

echo "=== [4/4] compress + checksum ==="
IMG=$HOME/soquartz-freebsd-arm64.img
zstd -T0 -3 -f "$IMG" -o "$IMG.zst"
( sha256 "$IMG" "$IMG.zst" 2>/dev/null || sha256sum "$IMG" "$IMG.zst" ) \
	| tee "$HOME/soquartz-freebsd-arm64.sha256"
ls -lh "$IMG.zst"
echo "=== DONE ==="
