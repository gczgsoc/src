#	$OpenBSD: Makefile.inc,v 1.20 2016/07/04 18:01:44 guenther Exp $

CFLAGS=${DEBUG} -Os -Wall -Werror
CPPFLAGS+=-I${S} -I. -I${.CURDIR}
SACFLAGS=-nostdinc -fno-builtin -D_STANDALONE -I${STANDIR}/libsa
SACFLAGS+=-mdisable-fpregs -mfast-indirect-calls -mpa-risc-1-1
SACFLAGS+=-fno-stack-protector
#DEBUGFLAGS=-DDEBUG
#DEBUGFLAGS+=-DPDCDEBUG
#DEBUGFLAGS+=-DLIFDEBUG
#DEBUGFLAGS+=-DEXEC_DEBUG
#DEBUGFLAGS+=-DALLOC_TRACE
LINKADDR=0xf80000
LOADADDR=0xf80000
HEAP_LIMIT=0xff8000
CLEANFILES+=	machine

.if !make(libdep) && !make(sadep) && !make(salibdir) && !make(obj) && !(defined(PROG) && ${PROG} == "mkboot")
.BEGIN:
	@([ -h machine ] || ln -s $(S)/arch/hppa/include machine)
.endif

.if exists(${STANDIR}/libsa/libsa.a)
LIBSA=${STANDIR}/libsa/libsa.a
.else
LIBSA=${STANDIR}/libsa/${__objdir}/libsa.a
.endif
.if exists(${STANDIR}/libz/libz.a)
LIBZ=${STANDIR}/libz/libz.a
.else
LIBZ=${STANDIR}/libz/${__objdir}/libz.a
.endif
.if exists(${STANDIR}/mkboot/mkboot)
MKBOOT=${STANDIR}/mkboot/mkboot
.else
MKBOOT=${STANDIR}/mkboot/${__objdir}/mkboot
.endif

BINDIR=	/usr/mdec
