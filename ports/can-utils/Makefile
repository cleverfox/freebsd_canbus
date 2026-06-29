PORTNAME=	can-utils
DISTVERSION=	g20250624
CATEGORIES=	comms

MAINTAINER=	devel@viruzzz.org
COMMENT=	SocketCAN userspace utilities (RAW-CAN) for the FreeBSD netcan stack
WWW=		https://github.com/linux-can/can-utils

LICENSE=	GPLv2 BSD2CLAUSE
LICENSE_COMB=	dual

# candump (and friends) use epoll(2); libepoll-shim provides it on FreeBSD.
LIB_DEPENDS=	libepoll-shim.so:devel/libepoll-shim

USE_GITHUB=	yes
GH_ACCOUNT=	linux-can
GH_TAGNAME=	95aae6bf83acbb1063a0ce9c2521279ab9f1132e

# FreeBSD/netcan adaptations are carried as a patch (files/patch-freebsd-netcan,
# applied automatically by the ports framework), NOT a fork: BSD sockaddr_can
# layout, <linux/*> compat shims (compat/), candump SIOCGIFNAME ->
# if_indextoname, devname -> cu_devname, and the freebsd-build.sh build script.
# See FREEBSD-PORT.md in this directory.

# RAW(CAN_RAW)-only tools that build and run against netcan. The protocol tools
# (isotp*/j1939*/bcm*/cangw/slcan*) and the SIOCGSTAMP-based cansniffer/
# canlogserver are intentionally not built (kernel features absent on FreeBSD).
BINS=		cansend candump cangen canplayer canbusload canfdtest \
		asc2log log2asc canerrsim
PLIST_FILES=	${BINS:S,^,bin/,}

do-build:
	cd ${WRKSRC} && ${SETENV} ${MAKE_ENV} CC="${CC}" ${SH} ./freebsd-build.sh

do-install:
.for b in ${BINS}
	${INSTALL_PROGRAM} ${WRKSRC}/${b} ${STAGEDIR}${PREFIX}/bin/${b}
.endfor

.include <bsd.port.mk>
