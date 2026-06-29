# Building can-utils on FreeBSD (netcan / PF_CAN stack)

These RAW-CAN tools build and run against the FreeBSD `netcan` kernel module
(`can.ko`, providing `AF_CAN`/`CAN_RAW` + `vcan`).

## Prerequisites
- The `netcan` kernel module loaded (`kldload can`) and a `vcan` interface
  (`ifconfig vcan0 create && ifconfig vcan0 up`).
- `pkg install libepoll-shim`  (candump uses epoll).

## Build
    ./freebsd-build.sh
Produces: cansend candump cangen canplayer canbusload canfdtest asc2log
log2asc canerrsim.

## What the FreeBSD port needed (compat/ directory)
The tools target Linux SocketCAN; the differences bridged here are:

1. **`sockaddr_can` ABI** — Linux has no `sa_len`; BSD sockets do, and the
   address family is a 1-byte field at offset 1.  `include/linux/can.h` is
   patched so `struct sockaddr_can` starts with `__u8 can_len; __u8 can_family;`
   (BSD layout).  `can_ifindex` still lands at offset 4, matching the kernel.
2. **Missing `<linux/*>` headers** — `compat/linux/{types,socket,stddef,sockios}.h`
   shim to the FreeBSD equivalents; `compat/linux/types.h` defines `__u8`..`__s64`
   and `__kernel_clockid_t`.
3. **`struct ifreq`** — Linux `ifr_ifindex` -> FreeBSD `ifr_index` (compat.h).
4. **`SIOCGIFNAME`** (index->name ioctl, Linux-only) -> `if_indextoname()`
   (patched in candump.c).
5. **Linux-only socket constants** — `SO_RCVBUFFORCE` (-> `SO_RCVBUF`),
   `SO_RXQ_OVFL`, `SO_TXTIME`, `SO_MARK`, `SO_PRIORITY`, `SCM_TXTIME`,
   `MSG_CONFIRM` (-> 0): defined as portable equivalents / no-ops in compat.h.
   They are only exercised by non-default options; the common paths work.
6. **`devname` symbol clash** with libc `devname(3)` — candump's static array
   renamed to `cu_devname`.
7. GNU Makefile -> use the standalone `freebsd-build.sh` (or `gmake`).

## Verified working
    ifconfig vcan0 create && ifconfig vcan0 up
    candump vcan0 &
    cansend vcan0 123#DEADBEEF                 # classic
    cansend vcan0 213##1112233445566778899AABBCCDDEEFF   # CAN FD + BRS
    cangen vcan0 -n 3 -g 50 -I 555 -L 4        # generate
    canplayer -I file.log                      # replay

## Not ported
- `cansniffer`, `canlogserver`: need `SIOCGSTAMP` (Linux last-RX-timestamp
  ioctl); requires reworking timestamps onto `SO_TIMESTAMP`/recvmsg cmsg.
- `isotp*`, `j1939*`, `bcm*` (bcmserver/cansequence), `cangw`, `slcan*`:
  require CAN protocols/features (ISOTP, J1939, BCM, gateway, slcan line
  discipline) not yet present in the FreeBSD kernel.
