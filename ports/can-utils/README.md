# can-utils FreeBSD port

FreeBSD has no `can-utils` package, so build it from this port. It uses the
**upstream** source — [github.com/linux-can/can-utils](https://github.com/linux-can/can-utils)
(pinned commit `95aae6b`) — and carries the FreeBSD/netcan adaptations as a
patch, `files/patch-freebsd-netcan` (applied automatically by the ports
framework). No fork. The changes are documented in `FREEBSD-PORT.md`:

- BSD `sockaddr_can` layout (`can_len`/`can_family`) in `include/linux/can.h`
- `<linux/*>` compat shims under `compat/`
- `candump`: `SIOCGIFNAME` → `if_indextoname`, `devname` → `cu_devname`
- a `freebsd-build.sh` that builds the RAW-CAN tools against `libepoll-shim`

## Install (as a port)
```sh
pkg install -y libepoll-shim
cp -R ports/can-utils /usr/ports/comms/can-utils      # or use a ports overlay
cd /usr/ports/comms/can-utils
make makesum            # fetch upstream tarball + record distinfo
make install clean      # installs cansend candump cangen canplayer canbusload
                        # canfdtest asc2log log2asc canerrsim into ${PREFIX}/bin
```

## Build without the ports framework
Apply the same patch to a fresh upstream checkout:
```sh
pkg install -y libepoll-shim
git clone https://github.com/linux-can/can-utils.git
cd can-utils && git checkout 95aae6b
patch -p0 < /path/to/ports/can-utils/files/patch-freebsd-netcan
sh ./freebsd-build.sh                                 # -> ./candump ./cansend ...
```

## Use
Needs the `netcan` module (`can.ko`) loaded — it's in the SOQuartz image, or
`kldload can`.
```sh
candump can0
cansend can0 123#DEADBEEF
cangen vcan0 -n 3 -g 50 -I 555 -L 4
```

Not built (kernel features absent on FreeBSD): `cansniffer`/`canlogserver`
(need `SIOCGSTAMP`), `isotp*`/`j1939*`/`bcm*`/`cangw`/`slcan*`.
