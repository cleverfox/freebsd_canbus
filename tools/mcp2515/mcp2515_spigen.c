/*
 * mcp2515_spigen - userspace MCP2515 bring-up tool over spigen(4).
 *
 * Prototyping aid used BEFORE the in-kernel mcp2515(4) driver exists: it talks
 * to the chip through /dev/spigenN.M so wiring, crystal value and the exact SPI
 * transaction framing can be validated with zero kernel risk.  It also serves
 * as the reference for the kernel driver's register sequences.
 *
 * Target: MCP2515 with an 8 MHz crystal, run at 3.3V (logic-compatible with the
 * Allwinner A64 / Pine A64).  Classic CAN 2.0B only.
 *
 * Build (on FreeBSD): cc -O2 -Wall -Wextra -o mcp2515 mcp2515_spigen.c
 *
 * Examples:
 *   mcp2515 -d /dev/spigen0.0 reset
 *   mcp2515 -d /dev/spigen0.0 regdump
 *   mcp2515 -d /dev/spigen0.0 selftest          # internal loopback, no bus
 *   mcp2515 -d /dev/spigen0.0 -b 250 send 123 de ad be ef
 *   mcp2515 -d /dev/spigen0.0 -b 250 monitor
 */

#include <sys/ioctl.h>
#include <sys/spigenio.h>

#include <err.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* SPI instruction set (datasheet table 12-1). */
#define	MCP_RESET	0xC0
#define	MCP_READ	0x03
#define	MCP_WRITE	0x02
#define	MCP_RTS		0x80	/* | (1<<n) for TXBn */
#define	MCP_READ_STATUS	0xA0
#define	MCP_RX_STATUS	0xB0
#define	MCP_BIT_MODIFY	0x05

/* Registers. */
#define	CANSTAT		0x0E
#define	CANCTRL		0x0F
#define	CNF3		0x28
#define	CNF2		0x29
#define	CNF1		0x2A
#define	CANINTE		0x2B
#define	CANINTF		0x2C
#define	EFLG		0x2D
#define	TXB0CTRL	0x30
#define	TXB0SIDH	0x31	/* SIDH,SIDL,EID8,EID0,DLC,D0.. follow */
#define	RXB0CTRL	0x60
#define	RXB0SIDH	0x61
#define	RXB1CTRL	0x70
#define	RXB1SIDH	0x71

/* CANCTRL/CANSTAT mode bits (REQOP / OPMOD, top 3 bits). */
#define	MODE_NORMAL	0x00
#define	MODE_SLEEP	0x20
#define	MODE_LOOPBACK	0x40
#define	MODE_LISTEN	0x60
#define	MODE_CONFIG	0x80
#define	MODE_MASK	0xE0

/* CANINTF bits. */
#define	RX0IF		0x01
#define	RX1IF		0x02

static int spifd = -1;

/*
 * One full-duplex SPI transaction with CS asserted for the whole buffer.
 * spigen overwrites the TX buffer with the bytes clocked in on MISO, so on
 * return buf[] holds the slave's response aligned to each clocked byte.
 */
static void
spi_xfer(uint8_t *buf, size_t n)
{
	struct spigen_transfer st;

	memset(&st, 0, sizeof(st));
	st.st_command.iov_base = buf;
	st.st_command.iov_len = n;
	if (ioctl(spifd, SPIGENIOC_TRANSFER, &st) < 0)
		err(1, "SPIGENIOC_TRANSFER");
}

static void
mcp_reset(void)
{
	uint8_t b = MCP_RESET;

	spi_xfer(&b, 1);
	usleep(10000);		/* osc start + internal reset */
}

static uint8_t
mcp_read(uint8_t addr)
{
	uint8_t b[3] = { MCP_READ, addr, 0x00 };

	spi_xfer(b, sizeof(b));
	return (b[2]);
}

static void
mcp_write(uint8_t addr, uint8_t val)
{
	uint8_t b[3] = { MCP_WRITE, addr, val };

	spi_xfer(b, sizeof(b));
}

static void
mcp_modify(uint8_t addr, uint8_t mask, uint8_t val)
{
	uint8_t b[4] = { MCP_BIT_MODIFY, addr, mask, val };

	spi_xfer(b, sizeof(b));
}

/* Burst write starting at addr (used to load a TX buffer in one transaction). */
static void
mcp_write_burst(uint8_t addr, const uint8_t *data, size_t n)
{
	uint8_t b[16];

	if (n + 2 > sizeof(b))
		errx(1, "burst too long");
	b[0] = MCP_WRITE;
	b[1] = addr;
	memcpy(&b[2], data, n);
	spi_xfer(b, n + 2);
}

/* Request a mode change and wait for CANSTAT to confirm it. */
static int
mcp_set_mode(uint8_t mode)
{
	int i;

	mcp_modify(CANCTRL, MODE_MASK, mode);
	for (i = 0; i < 100; i++) {
		if ((mcp_read(CANSTAT) & MODE_MASK) == mode)
			return (0);
		usleep(1000);
	}
	warnx("mode change to 0x%02x timed out (CANSTAT=0x%02x)",
	    mode, mcp_read(CANSTAT));
	return (-1);
}

/* 8 MHz crystal bit-timing table (75%% sample point). 500k is the ceiling. */
static int
mcp_set_bitrate(int kbit)
{
	uint8_t cnf1, cnf2, cnf3;

	switch (kbit) {
	case 500: cnf1 = 0x00; cnf2 = 0x91; cnf3 = 0x01; break;
	case 250: cnf1 = 0x00; cnf2 = 0xBA; cnf3 = 0x03; break;
	case 125: cnf1 = 0x01; cnf2 = 0xBA; cnf3 = 0x03; break;
	case 100: cnf1 = 0x01; cnf2 = 0xBD; cnf3 = 0x04; break;
	default:
		warnx("no 8MHz timing for %d kbit (use 100/125/250/500)", kbit);
		return (-1);
	}
	/* CNFx must be written in configuration mode. */
	mcp_write(CNF1, cnf1);
	mcp_write(CNF2, cnf2);
	mcp_write(CNF3, cnf3);
	return (0);
}

static void
mcp_load_tx(uint32_t id, const uint8_t *data, int len)
{
	uint8_t f[5 + 8];

	if (len < 0 || len > 8)
		errx(1, "dlc out of range");
	/* Standard 11-bit identifier (EXIDE = 0). */
	f[0] = (id >> 3) & 0xFF;		/* SIDH */
	f[1] = (id << 5) & 0xE0;		/* SIDL */
	f[2] = 0;				/* EID8 */
	f[3] = 0;				/* EID0 */
	f[4] = len & 0x0F;			/* DLC */
	memcpy(&f[5], data, len);
	mcp_write_burst(TXB0SIDH, f, 5 + len);
}

static void
mcp_rts(int txb)
{
	uint8_t b = MCP_RTS | (1 << txb);

	spi_xfer(&b, 1);
}

/* Read RX buffer n (0/1) if its CANINTF flag is set; returns len or -1. */
static int
mcp_recv(int n, uint32_t *id, uint8_t *data)
{
	uint8_t base = (n == 0) ? RXB0SIDH : RXB1SIDH;
	uint8_t flag = (n == 0) ? RX0IF : RX1IF;
	uint8_t sidh, sidl, dlc;
	int len, i;

	if ((mcp_read(CANINTF) & flag) == 0)
		return (-1);
	sidh = mcp_read(base + 0);
	sidl = mcp_read(base + 1);
	dlc = mcp_read(base + 4);
	*id = ((uint32_t)sidh << 3) | (sidl >> 5);
	len = dlc & 0x0F;
	for (i = 0; i < len; i++)
		data[i] = mcp_read(base + 5 + i);
	mcp_modify(CANINTF, flag, 0);	/* clear RXnIF */
	return (len);
}

static void
do_regdump(void)
{
	static const struct { const char *n; uint8_t a; } regs[] = {
		{ "CANSTAT", CANSTAT }, { "CANCTRL", CANCTRL },
		{ "CNF1", CNF1 }, { "CNF2", CNF2 }, { "CNF3", CNF3 },
		{ "CANINTE", CANINTE }, { "CANINTF", CANINTF },
		{ "EFLG", EFLG }, { "TXB0CTRL", TXB0CTRL },
		{ "RXB0CTRL", RXB0CTRL }, { "RXB1CTRL", RXB1CTRL },
	};
	size_t i;

	for (i = 0; i < sizeof(regs) / sizeof(regs[0]); i++)
		printf("  %-9s [0x%02x] = 0x%02x\n", regs[i].n, regs[i].a,
		    mcp_read(regs[i].a));
}

static int
do_selftest(int kbit)
{
	uint8_t tx[4] = { 0xDE, 0xAD, 0xBE, 0xEF };
	uint8_t rx[8];
	uint32_t id;
	int i, len;

	mcp_reset();
	if (mcp_set_mode(MODE_CONFIG) != 0)
		return (1);
	if (mcp_set_bitrate(kbit) != 0)
		return (1);
	/* Accept everything into RXB0 (turn off filters/masks). */
	mcp_modify(RXB0CTRL, 0x64, 0x60);	/* RXM=11: receive any */
	if (mcp_set_mode(MODE_LOOPBACK) != 0)
		return (1);

	mcp_load_tx(0x123, tx, sizeof(tx));
	mcp_rts(0);

	for (i = 0; i < 100; i++) {
		len = mcp_recv(0, &id, rx);
		if (len >= 0)
			break;
		usleep(1000);
	}
	if (len < 0) {
		warnx("selftest FAILED: no loopback frame received");
		printf("  CANINTF=0x%02x EFLG=0x%02x TXB0CTRL=0x%02x\n",
		    mcp_read(CANINTF), mcp_read(EFLG), mcp_read(TXB0CTRL));
		return (1);
	}
	printf("selftest: got id=0x%03x len=%d data=", id, len);
	for (i = 0; i < len; i++)
		printf("%02x", rx[i]);
	printf("\n");
	if (id == 0x123 && len == (int)sizeof(tx) &&
	    memcmp(rx, tx, sizeof(tx)) == 0) {
		printf("selftest PASSED (chip alive, timing OK, SPI framing OK)\n");
		return (0);
	}
	warnx("selftest FAILED: payload mismatch");
	return (1);
}

static int
do_send(int kbit, int argc, char **argv)
{
	uint8_t data[8];
	uint32_t id;
	int len, i;

	id = (uint32_t)strtoul(argv[0], NULL, 16);
	len = argc - 1;
	if (len > 8)
		errx(1, "at most 8 data bytes");
	for (i = 0; i < len; i++)
		data[i] = (uint8_t)strtoul(argv[i + 1], NULL, 16);

	mcp_reset();
	if (mcp_set_mode(MODE_CONFIG) != 0 || mcp_set_bitrate(kbit) != 0)
		return (1);
	if (mcp_set_mode(MODE_NORMAL) != 0)
		return (1);
	mcp_load_tx(id, data, len);
	mcp_rts(0);
	usleep(5000);
	if (mcp_read(TXB0CTRL) & 0x10) {	/* TXERR */
		warnx("send: TX error (no ACK? check bus/transceiver/term)");
		printf("  TXB0CTRL=0x%02x EFLG=0x%02x\n",
		    mcp_read(TXB0CTRL), mcp_read(EFLG));
		return (1);
	}
	printf("sent id=0x%03x len=%d\n", id, len);
	return (0);
}

static int
do_monitor(int kbit)
{
	uint8_t rx[8];
	uint32_t id;
	int n, len, i;

	mcp_reset();
	if (mcp_set_mode(MODE_CONFIG) != 0 || mcp_set_bitrate(kbit) != 0)
		return (1);
	mcp_modify(RXB0CTRL, 0x64, 0x60);	/* receive any */
	mcp_modify(RXB1CTRL, 0x60, 0x60);
	if (mcp_set_mode(MODE_NORMAL) != 0)
		return (1);
	printf("monitoring at %d kbit (^C to stop)...\n", kbit);
	for (;;) {
		for (n = 0; n < 2; n++) {
			len = mcp_recv(n, &id, rx);
			if (len < 0)
				continue;
			printf("  id=0x%03x len=%d data=", id, len);
			for (i = 0; i < len; i++)
				printf("%02x", rx[i]);
			printf("\n");
		}
		usleep(2000);
	}
	return (0);
}

static void
usage(void)
{
	fprintf(stderr,
	    "usage: mcp2515 [-d dev] [-c hz] [-b kbit] <command> [args]\n"
	    "  -d dev   spigen device (default /dev/spigen0.0)\n"
	    "  -c hz    SPI clock (default 5000000)\n"
	    "  -b kbit  CAN bitrate: 100|125|250|500 (default 500)\n"
	    "commands:\n"
	    "  reset                 reset the chip\n"
	    "  regdump               dump key registers\n"
	    "  rd <addr>             read one register (hex)\n"
	    "  wr <addr> <val>       write one register (hex)\n"
	    "  selftest              internal-loopback TX/RX (no bus needed)\n"
	    "  send <id> [byte..]    send one frame in normal mode (hex)\n"
	    "  monitor               receive frames in normal mode\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	const char *dev = "/dev/spigen0.0";
	uint32_t clock = 5000000, mode = 0;
	int kbit = 500, ch;

	while ((ch = getopt(argc, argv, "b:c:d:")) != -1) {
		switch (ch) {
		case 'b': kbit = atoi(optarg); break;
		case 'c': clock = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'd': dev = optarg; break;
		default: usage();
		}
	}
	argc -= optind;
	argv += optind;
	if (argc < 1)
		usage();

	if ((spifd = open(dev, O_RDWR)) < 0)
		err(1, "open %s", dev);
	if (ioctl(spifd, SPIGENIOC_SET_SPI_MODE, &mode) < 0)
		warn("SPIGENIOC_SET_SPI_MODE");	/* MCP2515 = mode 0,0 */
	if (ioctl(spifd, SPIGENIOC_SET_CLOCK_SPEED, &clock) < 0)
		warn("SPIGENIOC_SET_CLOCK_SPEED");

	if (strcmp(argv[0], "reset") == 0) {
		mcp_reset();
		printf("reset done (CANSTAT=0x%02x, expect 0x80 = config)\n",
		    mcp_read(CANSTAT));
	} else if (strcmp(argv[0], "regdump") == 0) {
		do_regdump();
	} else if (strcmp(argv[0], "rd") == 0 && argc == 2) {
		uint8_t a = (uint8_t)strtoul(argv[1], NULL, 16);
		printf("[0x%02x] = 0x%02x\n", a, mcp_read(a));
	} else if (strcmp(argv[0], "wr") == 0 && argc == 3) {
		mcp_write((uint8_t)strtoul(argv[1], NULL, 16),
		    (uint8_t)strtoul(argv[2], NULL, 16));
	} else if (strcmp(argv[0], "selftest") == 0) {
		return (do_selftest(kbit));
	} else if (strcmp(argv[0], "send") == 0 && argc >= 2) {
		return (do_send(kbit, argc - 1, argv + 1));
	} else if (strcmp(argv[0], "monitor") == 0) {
		return (do_monitor(kbit));
	} else {
		usage();
	}
	return (0);
}
