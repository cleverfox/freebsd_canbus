# FreeBSD SocketCAN on the Pine64 SOQuartz (RK3566)

A reproducible build of a **bootable FreeBSD 16-CURRENT/arm64 image** for the
Pine64 **SOQuartz** compute module (RK3566) on the **Model A** carrier, with a
Linux-compatible **SocketCAN (`PF_CAN` / `netcan`)** stack and **two ways to put
real CAN frames on the wire**:

- **Scenario A — MCP2515**: a Microchip MCP2515 classic-CAN controller on SPI,
  driven by an in-kernel `mcp2515(4)` driver → a `can0` interface.
- **Scenario B — slcan bridge**: a serial/TCP SLCAN (Lawicel) adapter bridged
  into a `slcanN` interface by the `slcand` daemon. Reference adapter firmware:
  [espcan_br](https://github.com/cleverfox/espcan_br) for the WeAct CAN485
  ESP32 board.

Both expose standard `AF_CAN` `SOCK_RAW` sockets, so `can-utils`
(`candump`/`cansend`), `tcpdump`, and your own software work unmodified.

---

## Source code

- **FreeBSD tree:** <https://github.com/cleverfox/freebsd-src> branch **`canbus`**
  — the `netcan` PF_CAN stack, `slcand`, the `mcp2515(4)` driver, and the
  `rk_spi` interrupt-relay fix are all committed there.
- **Two device-tree changes** are *not* in the branch yet and must be applied
  from `patches/` (see below).
- **This repo** carries the build tooling, device-tree overlays, the U-Boot
  port, and these docs.

```
patches/    device-tree patches to apply on top of the canbus branch
scripts/    U-Boot + image build scripts (run on the build host)
overlays/   device-tree overlays (MCP2515 driver / spigen tool)
release/    release(7) board config (SOQUARTZ.conf), upstreaming reference
ports/      FreeBSD ports: u-boot-soquartz-model-a, can-utils (upstream + netcan patch)
tools/      mcp2515 spigen userspace bring-up tool
```

---

## 1. Build host

FreeBSD doesn't cross-build from non-FreeBSD hosts, so you need a **FreeBSD/amd64
builder** (it cross-compiles to arm64). ~16 cores / 50+ GB free is comfortable.
You need passwordless `sudo`.

Install the U-Boot toolchain and image tools as **binary packages** (building
the cross-toolchain from ports hits a `texinfo`/`perl5` issue):

```sh
sudo pkg install -y aarch64-none-elf-gcc gsed rkbin bison flex gawk \
    gmake pkgconf python3 swig dtc py311-pyelftools zstd
```
(`makefs`, `mkimg`, `gpart`, `mdconfig`, `newfs_msdos` are in the base system.)

### Get the sources on the build host
```sh
# FreeBSD tree + patches
git clone -b canbus https://github.com/cleverfox/freebsd-src.git ~/src
cd ~/src
git apply /path/to/this-repo/patches/0001-soquartz-model-a-sd-vmmc-supply.patch
git apply /path/to/this-repo/patches/0002-build-soquartz-model-a-dtb.patch

# U-Boot 2025.04 source for the SOQuartz bootloader build
fetch -o /tmp/u-boot-2025.04.tar.bz2 https://ftp.denx.de/pub/u-boot/u-boot-2025.04.tar.bz2
tar xf /tmp/u-boot-2025.04.tar.bz2 -C ~/ && mv ~/u-boot-2025.04 ~/ubuild

# this repo (scripts expect to be run from its checkout)
git clone https://github.com/cleverfox/freebsd_canbus.git ~/soquartz-can   # any path; run scripts from here
```

> The two patches fix real bugs: the SOQuartz microSD `vmmc-supply` points at a
> *disabled* regulator (U-Boot then can't power the card — "did not respond to
> voltage select"), and the SOQuartz Model A DTB isn't in the kernel's DTB build
> list. Both are upstreamable.

---

## 2. Build the image

One command does U-Boot → kernel+modules → rootfs → image → checksum:

```sh
# first time only: build world (≈30–60 min)
cd ~/src && env MAKEOBJDIRPREFIX=$HOME/obj __MAKE_CONF=/dev/null SRCCONF=/dev/null \
    make -j$(sysctl -n hw.ncpu) TARGET=arm64 TARGET_ARCH=aarch64 buildworld

# build everything else + assemble the image
sh ~/soquartz-can/scripts/build-image-complete.sh
```

Output: `~/soquartz-freebsd-arm64.img` (+ `.img.zst` and `.sha256`).

The image contains: a stock **GENERIC** kernel (with the `rk_spi` interrupt-relay
fix), `can.ko` + `mcp2515.ko`, the SOQuartz Model A DTB, the **MCP2515 CAN
overlay** enabled in `loader.conf`, `slcand`, the `mcp2515` spigen tool, and a
**passwordless root**. U-Boot is built from the mainline
`soquartz-model-a` defconfig (the prebuilt `u-boot-quartz64-a` package bootloops
on this board).

What the scripts do (see `scripts/` for details):
- `build-uboot.sh` — builds `idbloader.img` + `u-boot.itb` from `~/ubuild` with
  the rkbin TF-A BL31 + RK3566 DDR blob.
- `mk-image.sh` — `installworld`/`installkernel` → `~/rootfs`, writes
  `fstab`/`loader.conf`/`rc.conf`, makes root passwordless, cross-builds the
  spigen tool, compiles the CAN overlay into `/boot/dtb/overlays`, `makefs` the
  UFS, lays out the GPT with `gpart`, and `dd`s U-Boot into the reserved gap.

---

## 3. Flash and first boot

```sh
zstd -d soquartz-freebsd-arm64.img.zst
# pick the right device! (macOS: /dev/rdiskN after `diskutil list`)
sudo dd if=soquartz-freebsd-arm64.img of=/dev/diskN bs=4m
```
- Use a **good-quality** microSD. A marginal card shows up as a U-Boot
  `Card did not respond to voltage select! : -110` and a hang at the loader.
- Console: 3.3 V USB-serial on the debug UART, **1500000 8N1**.
- It **autoboots** (no manual U-Boot interaction) and you log in as **`root`
  with an empty password** (just Enter). Set one with `passwd`.
- DHCP + sshd are on. To grow the rootfs to the card: it auto-`growfs`es; if the
  GPT secondary header warning bothers you, `gpart recover mmcsd0`.

Sanity check the CAN stack (no hardware needed):
```sh
kldstat | grep can
ifconfig vcan0 create up           # virtual CAN loopback
```

---

## 4. Scenario A — MCP2515 (in-kernel SPI driver → `can0`)

### Wiring (SOQuartz Model A 40-pin header, SPI3 "M0" pins)
Run the MCP2515 at **3.3 V** with an **8 MHz crystal** (see
`tools/mcp2515/README.md` for the 3.3 V mod and transceiver level notes; 500
kbit/s is the 8 MHz ceiling).

| MCP2515 | RK3566 pin | function |
|---|---|---|
| SCK | GPIO4_B3 | spi3 clk |
| SI  | GPIO4_B2 | spi3 mosi |
| SO  | GPIO4_B0 | spi3 miso |
| CS  | GPIO4_A6 | spi3 cs0 |
| INT | GPIO4_B1 | GPIO interrupt (level-low) |
| VCC | 3.3 V | |
| GND | GND | |
| CANH/CANL | to the CAN bus | via the transceiver |

### It's already enabled
The image ships `mcp2515_load="YES"` and
`fdt_overlays="rk3566-soquartz-mcp2515-can.dtbo"` in `/boot/loader.conf`, so on
boot the driver attaches and you get `can0`:
```sh
dmesg | grep -i mcp2515            # "<can0> ... 8 MHz xtal, default 500 kbit/s"
ifconfig can0
```
If no chip is wired, the driver simply logs "MCP2515 not responding" and `can0`
is absent — no panic.

### Configure the bitrate (live)
```sh
sysctl dev.mcp2515.0.bitrate=125   # 100 | 125 | 250 | 500 (8 MHz table)
```
It reprograms the controller immediately (cycles config→normal). Persist across
reboots in `/etc/sysctl.conf`:
```
dev.mcp2515.0.bitrate=125
```
**Both ends of the bus must use the same bitrate.**

### Bring it up and test
```sh
ifconfig can0 up
# can-utils isn't a FreeBSD package -- build it from ports/can-utils first
candump can0 &
cansend can0 123#DEADBEEF          # needs ≥1 other node on the bus to ACK
```

---

## 5. Scenario B — slcan bridge (serial / TCP → `slcanN`)

FreeBSD has no `N_SLCAN` line discipline, so `slcand` (in the canbus branch,
installed in the image) bridges an SLCAN/Lawicel adapter into a `slcanN`
interface, in userspace:

```
adapter (serial SLCAN | TCP) <-> slcand <-> /dev/slcanN <-> AF_CAN sockets
```

The reference adapter is the **WeAct CAN485 DevBoard V1 (classic ESP32)** running
[**espcan_br**](https://github.com/cleverfox/espcan_br) — a `no_std` async Rust
SLCAN bridge. It exposes the CAN bus as an SLCAN adapter over **two transports at
once**: the **USB-serial port (UART0, 115200 8N1)** and a **TCP server on port
2000** over WiFi; it can also **dial out** as a TCP client. Each transport (and
each TCP connection) is an independent SLCAN port with its own `O`/`C`. Build and
flash per the espcan_br repo, then configure WiFi (below) and bridge it on the
FreeBSD side.

> WiFi setup: with no saved credentials the board boots a config AP `espcan-br`
> (192.168.4.1) with an HTTP setup page — enter SSID/password, it reboots and
> joins your network (its station IP is shown on the page; it also advertises
> itself over mDNS as `espcan-br`, and the UART baud is configurable there). The
> SLCAN TCP server (:2000) runs on both the AP and the station IP. For an
> outbound (NAT-friendly) client connection, set a `tcp://host:port/` URL on that
> page. (Ignore the firmware's `tls://` option — that's for a different project.)

`slcand` usage (FreeBSD, from the canbus branch):
```
serial:      slcand [opts] <serialdev> [ifname]
TCP server:  slcand [opts] -p <port>      [ifname]   # listen; adapter dials in
TCP client:  slcand [opts] -t <host:port> [ifname]   # connect to the adapter
  -o          send "open channel" (O) to the adapter
  -c          send "close channel" (C) on exit
  -s <0-8>    CAN bitrate code: S0=10k S1=20k S2=50k S3=100k S4=125k
                                S5=250k S6=500k S7=800k S8=1M
  -b <baud>   serial UART baud (default 115200 = the board's UART0 rate)
  -v          print bridged frames (candump-like)
  [ifname]    interface to create (default slcan0)
```
Bitrate must match both ends; the firmware supports **S2–S8** (S0/S1 unsupported
on the classic ESP32) and defaults to **S6 (500 kbit)** if unset.

### B1 — Serial (USB-UART)
The board's USB-serial ↔ a FreeBSD host (`/dev/cuaU0`; default 115200 matches the
firmware). Open the channel at 125 kbit/s and create `slcan0`:
```sh
slcand -o -c -s4 /dev/cuaU0 slcan0     # -s4 = 125 kbit/s
ifconfig slcan0 up
candump slcan0
```

### B2 — TCP, board as server (port 2000)
The firmware listens on **:2000**; point `slcand` at it as a client:
```sh
slcand -o -c -s4 -t <board-station-ip>:2000 slcan0
ifconfig slcan0 up
```

### B3 — TCP, board dials out (client / behind NAT)
Run `slcand` as a **server** on a reachable FreeBSD host, then set the board's
auto-connect URL (web page) to `tcp://<that-host-ip>:<port>/`:
```sh
slcand -o -c -s4 -p 9000 slcan0        # FreeBSD listens; board connects out
ifconfig slcan0 up
```

> `slcand`'s TCP modes also tunnel a CAN bus **between two FreeBSD machines** (the
> SLCAN wire format is identical on serial and TCP): one `-p` server, one `-t`
> client, and the two `slcanN` interfaces share a virtual bus.

### Enable at boot
`rc.conf` has a commented template; for a serial adapter:
```
slcand_enable="YES"
slcand_flags="-o -s4 /dev/cuaU0"
```

---

## 6. Testing CAN (both scenarios)

`can-utils` is **not a FreeBSD package** — build it from this repo's
`ports/can-utils/` (upstream `linux-can/can-utils` + a netcan patch, no fork;
see that dir's README):
```sh
pkg install -y libepoll-shim
cp -R ports/can-utils /usr/ports/comms/can-utils
cd /usr/ports/comms/can-utils && make makesum && make install clean
```
Then:
```sh
candump -tz can0                 # timestamped dump (or slcan0)
cansend can0 5A1#1122334455667788
tcpdump -ni can0                 # BPF also works on CAN interfaces (no build needed)
```
- A classic CAN frame needs an **ACK from ≥1 other node**; a lone transmitter
  will retry/flag errors (`ifconfig`/`netstat` counters, MCP2515 `regdump`).
- For a quick TX↔RX check without a bus, use `vcan` or the MCP2515 spigen
  `selftest` (internal loopback).
- Cross-test the two scenarios against each other: an MCP2515 `can0` on one
  board and an slcan `slcan0` (ESP485) on another, on the same physical bus, at
  the same bitrate.

---

## 7. What's in the `canbus` branch (the changes)

The FreeBSD-side work, for reference / upstreaming:
- **`netcan`** — the `PF_CAN`/`AF_CAN` family: `CAN_RAW` sockets, `can_input`/
  `can_if_output`, `vcan`/`cantap`, BPF (`DLT_CAN_SOCKETCAN`).
- **`usr.sbin/slcand`** — the serial/TCP SLCAN bridge daemon + rc.d service.
- **`sys/dev/mcp2515/if_mcp2515.c`** — the MCP2515 driver (classic CAN).
- **`rk_spi` fix** — added bus resource-relay methods so an SPI child can
  allocate its FDT GPIO interrupt (needed by any IRQ-driven SPI device on
  Rockchip, not just CAN).
- Build wiring for the CAN module + headers; ATF tests for `CAN_RAW`.

Plus the two device-tree patches in `patches/` (SD `vmmc` fix + SOQuartz DTB
build entry), the `release/arm64/SOQUARTZ.conf` board config, and the
`sysutils/u-boot-soquartz-model-a` port.

---

## 8. Known issues / TODO

- **eMMC boot doesn't work yet.** The image boots from microSD; on the SoM eMMC
  the kernel can't enumerate it (`mmc1: CMD3 failed`) because FreeBSD's
  `rk3568_cru` driver can't set the `cclk_emmc` clock. SD is the supported boot
  medium for now.
- **MCP2515 driver** is classic-CAN only (no CAN FD), single TX buffer, bitrate
  via sysctl (no netlink bit-timing / bus-off restart yet); the attach
  error-path cleanup needs hardening before upstreaming.
- **Marginal microSD cards** fail U-Boot's SD re-init (`-110`) intermittently —
  use a known-good card.

