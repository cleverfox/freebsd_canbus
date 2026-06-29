# MCP2515 on FreeBSD / Pine A64 — bring-up kit

Pre-hardware prototyping for a future in-kernel `mcp2515(4)` driver. Validates
the chip, wiring and SPI framing from userspace via `spigen(4)` before any kernel
code is written, and pins down the register sequences the driver will reuse.

Target: **MCP2515 + 8 MHz crystal, run at 3.3V**, classic CAN 2.0B only, on a
**Pine A64 LTS** (Allwinner A64). FreeBSD already has the needed controller
drivers — `aw_spi` (SPI master), `aw_gpio` (GPIO interrupt PIC), `spigen`.

## Hardware notes

- **3.3V mod:** cut the shared-VCC track so the MCP2515 runs from a 3.3V LDO
  while the TJA1050 stays at 5V. This gives 3.3V SPI/INT levels to the A64.
- **Cross-domain signal pair to check** (MCP2515 3.3V ↔ TJA1050 5V):
  - `TJA1050 RXD` (0–5V) → `MCP2515 RXCAN` (3.3V input): 5V exceeds the MCP2515
    abs-max (VDD+0.3). Add a series R / small divider on this line, or use a
    3.3V-native transceiver (MCP2562 with VIO, or SN65HVD230).
  - `MCP2515 TXCAN` (3.3V) → `TJA1050 TXD` (5V input): usually OK, but the
    marginal direction — first suspect if TX misbehaves.
- **Bitrate ceiling:** an 8 MHz crystal tops out at **500 kbit/s** for valid CAN
  timing (1 Mbit/s needs ≥5 TQ/bit but 8 MHz only yields 4 → impossible). Use
  16 MHz crystals if a bus needs 1 Mbit/s.

## 8 MHz bit timing (75% sample point)

| Bitrate | CNF1 | CNF2 | CNF3 |
|--------:|:----:|:----:|:----:|
| 500k (max) | 0x00 | 0x91 | 0x01 |
| 250k | 0x00 | 0xBA | 0x03 |
| 125k | 0x01 | 0xBA | 0x03 |
| 100k | 0x01 | 0xBD | 0x04 |

## Wiring (confirm pins against the Pine A64 LTS schematic)

`spi0` carries the SOPine on-module boot flash, so use **`spi1`** (or a free CS
of spi0). MCP2515 is SPI mode 0,0.

| MCP2515 | A64 |
|---------|-----|
| SCK  | spi1 CLK |
| SI   | spi1 MOSI |
| SO   | spi1 MISO |
| CS   | spi1 CS0 |
| INT  | a free GPIO (becomes an FDT interrupt via `&pio`) |
| VCC  | 3.3V (post-mod) |
| GND  | GND |

## Build & use (on the board)

```sh
cc -O2 -Wall -Wextra -o mcp2515 mcp2515_spigen.c

./mcp2515 -d /dev/spigen0.0 reset          # expect CANSTAT=0x80 (config mode)
./mcp2515 -d /dev/spigen0.0 regdump
./mcp2515 -d /dev/spigen0.0 selftest       # internal loopback, no bus needed
./mcp2515 -d /dev/spigen0.0 -b 250 send 123 de ad be ef
./mcp2515 -d /dev/spigen0.0 -b 250 monitor
```

## Bring-up order

1. Enable spi1 + spigen via the overlay (`mcp2515-pine64.dtso`), reboot, confirm
   `/dev/spigen1.0` (or `spigen0.0`) appears.
2. `reset` → CANSTAT should read `0x80`. If not: SPI wiring/mode/clock.
3. `selftest` → proves chip alive + timing + framing, without a transceiver/bus.
4. Connect the transceiver + a second node, then `send` / `monitor`.
5. Once all four steps pass, that register sequence becomes the kernel driver's
   attach/timing/TX/RX paths.
