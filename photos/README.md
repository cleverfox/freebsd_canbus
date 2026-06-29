# Photos

- `fix_tja1050_0.jpg` — bottom of the AliExpress MCP2515/TJA1050 module: the
  single TJA1050 power-supply track to cut.
- `fix_tja1050_1.jpg` — after the cut, with 5 V fed directly to the TJA1050
  power capacitor.
- `fix_tja1050_2.jpg` — 100 Ohm series resistor on TJA1050 pin 4 (RXD) into the
  MCP2515 RXCAN line: pin 4 lifted, a vertical 0402 between track and pin.
- `soquartz_tja1050.jpg` — full bench: SOQuartz on its baseboard with the
  modified MCP2515 board (3.3 V orange to the MCP2515, 5 V red to the TJA1050),
  and a second CAN node on a WeAct CAN485 ESP32.
