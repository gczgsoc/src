#	$OpenBSD: Makefile,v 1.3 2016/09/03 10:56:58 bluhm Exp $
#	$EOM: Makefile,v 1.6 2000/03/28 21:22:07 ho Exp $

# Test PRF:

PROG=		prftest
SRCS=		prf.c hash.c log.c prftest.c conf.c monitor.c util.c
TOPSRC=		${.CURDIR}/../../../../sbin/isakmpd
TOPOBJ!=	cd ${TOPSRC}; printf "all:\n\t@pwd\n" |${MAKE} -f-
.PATH:		${.CURDIR}/../common
.PATH:		${TOPSRC} ${TOPSRC}/sysdep/openbsd ${TOPOBJ}
CFLAGS+=	-I${TOPSRC} -I${TOPSRC}/sysdep/openbsd -I${TOPOBJ} -Wall
NOMAN=
DEBUG=		-g

.PHONY:	isakmpd-depend

all regress: isakmpd-depend

isakmpd-depend:
	cd ${TOPSRC} && ${MAKE} depend

.include <bsd.regress.mk>
