#!/bin/sh
#
# mk-image.sh -- assemble a bootable FreeBSD/arm64 microSD image for the
# Pine64 SOQuartz (RK3566) on the Model A carrier, with the SocketCAN
# (PF_CAN / netcan) stack included as a loadable module (can.ko).
#
# Runs on the amd64 FreeBSD *build host* after a successful
#   make TARGET=arm64 TARGET_ARCH=aarch64 buildworld buildkernel KERNCONF=GENERIC
# It cross-installs world+kernel into a DESTDIR, customizes it, builds the
# root UFS with makefs(8) (preserves file flags, no chroot needed), lays out a
# GPT image with gpart(8) on a memory disk, drops the FreeBSD EFI loader into an
# ESP, and dd's the Rockchip U-Boot blobs into the reserved gap.
#
# Requires: passwordless sudo (mdconfig/gpart/mount/dd), makefs, mkimg, pwd_mkdb.
# Root is made passwordless by editing master.passwd + host pwd_mkdb (no chroot,
# no qemu -- amd64/arm64 are both little-endian so the password DB is portable).
#
# Tunables (override via environment):
set -eu

: "${SRC:=$HOME/src}"
: "${OBJ:=$HOME/obj}"
: "${DESTDIR:=$HOME/rootfs}"
: "${IMG:=$HOME/soquartz-freebsd-arm64.img}"
# dir holding idbloader.img + u-boot.itb -- build these with build-uboot.sh
# (soquartz-model-a defconfig); the quartz64-a pkg bootloops on this board.
: "${UBOOT:=$HOME/uboot}"
: "${OVERLAY:=$HOME/soquartz/files}"      # optional drop-in etc/boot files
: "${MCP2515_SRC:=$HOME/mcp2515/mcp2515_spigen.c}"  # bring-up tool source (optional)
: "${MCP2515_OVERLAY:=$HOME/soquartz/overlays/rk3566-soquartz-mcp2515-can.dtso}"  # CAN driver overlay (optional)
# kernel driver to autoload for the overlay above: mcp2515 (classic CAN) or
# mcp251xfd (MCP2517/2518FD, CAN FD) -- must match the overlay's compatible
: "${CAN_DRIVER:=mcp2515}"
CAN_DTBO="$(basename "$MCP2515_OVERLAY" .dtso).dtbo"

KERNCONF=GENERIC
TARGET=arm64
TARGET_ARCH=aarch64
DTB="rockchip/rk3566-soquartz-model-a.dtb"

# image geometry (MB)
IMAGE_SIZE_M=4608      # total image
ESP_OFFSET_M=16        # leave the first 16 MB free for U-Boot (idbloader@64s, itb@16384s)
ESP_SIZE_M=50          # EFI system partition (FAT16)
ROOTFS_MAKEFS_M=3072   # size of the UFS built by makefs; growfs expands to fill p2 on boot

# Root is passwordless by default (lab bring-up image). Set a password after
# first boot with passwd(1).

CONSOLE_SPEED="${CONSOLE_SPEED:-1500000}"  # Rockchip debug UART default baud

MAKE="env MAKEOBJDIRPREFIX=$OBJ __MAKE_CONF=/dev/null SRCCONF=/dev/null \
      make -C $SRC TARGET=$TARGET TARGET_ARCH=$TARGET_ARCH"

say() { echo ">>> $*"; }

# ---------------------------------------------------------------------------
say "installworld / installkernel / distribution -> $DESTDIR"
# installworld sets schg (immutable) flags on some binaries; clear them before
# removing a previous DESTDIR.
if [ -d "$DESTDIR" ]; then
	sudo chflags -R noschg "$DESTDIR" 2>/dev/null || true
	sudo rm -rf "$DESTDIR"
fi
sudo mkdir -p "$DESTDIR"
sudo sh -c "$MAKE DESTDIR=$DESTDIR KERNCONF=$KERNCONF installkernel"
sudo sh -c "$MAKE DESTDIR=$DESTDIR installworld"
sudo sh -c "$MAKE DESTDIR=$DESTDIR distribution"

# ---------------------------------------------------------------------------
say "customizing rootfs (fstab, loader.conf, rc.conf)"

sudo tee "$DESTDIR/etc/fstab" >/dev/null <<EOF
# Device                Mountpoint  FStype  Options      Dump  Pass
/dev/ufs/rootfs         /           ufs     rw           1     1
/dev/msdosfs/EFISYS     /boot/efi   msdosfs rw,noauto    0     0
EOF

# loader.conf: serial+efi console, autoload the CAN module, and FORCE the
# SOQuartz Model A DTB over the one quartz64-a U-Boot hands us via EFI.
# (The EFI loader ignores fdt_file; it does honor a file preloaded as type
# "dtb", which fdt_setup_fdtp() prefers over the EFI-provided blob.)
sudo tee -a "$DESTDIR/boot/loader.conf" >/dev/null <<EOF

# --- SOQuartz / SocketCAN image ---
boot_serial="YES"
console="comconsole,efi"
comconsole_speed="$CONSOLE_SPEED"

# SocketCAN (PF_CAN) -- loadable module, GENERIC kernel
can_load="YES"

# Microchip CAN controller on SPI3 CS0 -> can0 (driver auto-loads can.ko).
# The overlay enables SPI3 + the controller node; if no chip is wired the
# driver just fails to attach, no panic.
${CAN_DRIVER}_load="YES"
fdt_overlays="$CAN_DTBO"

# Force the SOQuartz Model A device tree (overrides U-Boot's EFI FDT)
dtbfile_load="YES"
dtbfile_type="dtb"
dtbfile_name="/boot/dtb/$DTB"
EOF

sudo tee "$DESTDIR/etc/rc.conf" >/dev/null <<EOF
hostname="soquartz"
growfs_enable="YES"
sshd_enable="YES"
ifconfig_DEFAULT="DHCP"
# CAN userland: uncomment to auto-start the slcan bridge on a serial adapter
#slcand_enable="YES"
#slcand_flags="-o -s6 /dev/cuaU0"
EOF

# Optional drop-in overlay (anything under $OVERLAY is copied verbatim).
if [ -d "$OVERLAY" ]; then
	say "applying overlay $OVERLAY"
	sudo cp -R "$OVERLAY"/ "$DESTDIR"/ 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# ports prefix (distribution(7) doesn't create /usr/local) for the mcp2515 tool.
sudo mkdir -p "$DESTDIR/usr/local/bin"

# ---------------------------------------------------------------------------
# Cross-compile and bundle the MCP2515 spigen bring-up tool, if present.
if [ -f "$MCP2515_SRC" ]; then
	say "cross-compiling mcp2515 bring-up tool"
	XCC="$OBJ$SRC/$TARGET.$TARGET_ARCH/tmp/usr/bin/cc"
	# native build host (host arch == target): no cross cc in tmp, host cc is fine
	if [ ! -x "$XCC" ] && [ "$(uname -p)" = "$TARGET_ARCH" ]; then
		XCC=/usr/bin/cc
	fi
	if [ -x "$XCC" ]; then
		"$XCC" -O2 -Wall -o /tmp/mcp2515 "$MCP2515_SRC" \
			&& sudo install -m 0755 /tmp/mcp2515 "$DESTDIR/usr/local/bin/mcp2515" \
			&& say "  installed /usr/local/bin/mcp2515"
	else
		say "  (cross cc not found at $XCC; shipping source under /root)"
		sudo mkdir -p "$DESTDIR/root/mcp2515"
		sudo cp "$MCP2515_SRC" "$DESTDIR/root/mcp2515/"
	fi
fi

# ---------------------------------------------------------------------------
# Compile the MCP2515 CAN driver overlay into /boot/dtb/overlays (referenced by
# fdt_overlays in loader.conf). Label-based (&spi3/&gpio4); the base DTB is
# built with `dtc -@` so the loader resolves the fixups at boot.
if [ -f "$MCP2515_OVERLAY" ]; then
	say "compiling CAN overlay $CAN_DTBO"
	sudo mkdir -p "$DESTDIR/boot/dtb/overlays"
	dtc -@ -I dts -O dtb -o "/tmp/$CAN_DTBO" "$MCP2515_OVERLAY"
	sudo cp "/tmp/$CAN_DTBO" "$DESTDIR/boot/dtb/overlays/$CAN_DTBO"
fi

# ---------------------------------------------------------------------------
# Make root passwordless (console/serial login with just Enter). Done by
# emptying root's password field in master.passwd and rebuilding the password
# databases with the HOST pwd_mkdb -- amd64 and arm64 are both little-endian, so
# the generated *.db are byte-compatible with the target. This replaces the
# earlier `pw` under qemu-user, which produced a password DB the target rejected.
say "making root passwordless"
sudo sed -i '' -E 's/^root:[^:]*:/root::/' "$DESTDIR/etc/master.passwd"
sudo pwd_mkdb -p -d "$DESTDIR/etc" "$DESTDIR/etc/master.passwd"

# ---------------------------------------------------------------------------
say "building root UFS with makefs ($ROOTFS_MAKEFS_M MB)"
ROOTUFS="$HOME/root.ufs"
rm -f "$ROOTUFS"
sudo makefs -t ffs -B little \
	-s ${ROOTFS_MAKEFS_M}m \
	-o label=rootfs,version=2,softupdates=1 \
	"$ROOTUFS" "$DESTDIR"
sudo chown "$(id -un)" "$ROOTUFS"

# ---------------------------------------------------------------------------
say "creating GPT image $IMG ($IMAGE_SIZE_M MB)"
rm -f "$IMG"
truncate -s ${IMAGE_SIZE_M}m "$IMG"
md=$(sudo mdconfig -a -t vnode -f "$IMG")
trap 'sudo mdconfig -d -u "$md" 2>/dev/null || true' EXIT
say "  memory disk: $md"

sudo gpart create -s gpt "/dev/$md"
sudo gpart add -t efi          -b ${ESP_OFFSET_M}m -s ${ESP_SIZE_M}m -l EFISYS "/dev/$md"   # p1
sudo gpart add -t freebsd-ufs                                       -l rootfs "/dev/$md"    # p2

# ESP: FAT16 with the FreeBSD EFI loader as the removable-media default boot file
say "  populating EFI system partition"
sudo newfs_msdos -L EFISYS -F 16 "/dev/${md}p1" >/dev/null
espmnt=$(mktemp -d)
sudo mount -t msdosfs "/dev/${md}p1" "$espmnt"
sudo mkdir -p "$espmnt/EFI/BOOT"
sudo cp "$DESTDIR/boot/loader.efi" "$espmnt/EFI/BOOT/BOOTAA64.EFI"
sudo umount "$espmnt"; rmdir "$espmnt"

# Root: write the makefs UFS straight into p2 (growfs expands it on first boot)
say "  writing root UFS into p2"
sudo dd if="$ROOTUFS" of="/dev/${md}p2" bs=1m conv=sync status=none

# U-Boot (Rockchip): idbloader at LBA 64, u-boot.itb at LBA 16384 -- both land
# in the 16 MB gap reserved ahead of p1.
say "  writing Rockchip U-Boot blobs"
sudo dd if="$UBOOT/idbloader.img" of="/dev/$md" seek=64    bs=512 conv=sync,notrunc status=none
sudo dd if="$UBOOT/u-boot.itb"    of="/dev/$md" seek=16384 bs=512 conv=sync,notrunc status=none

sudo mdconfig -d -u "$md"; trap - EXIT
say "DONE: $IMG"
ls -lh "$IMG"
