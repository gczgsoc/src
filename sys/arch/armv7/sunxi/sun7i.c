/* $OpenBSD: sun7i.c,v 1.7 2016/10/09 11:14:22 kettenis Exp $ */

/*
 * Copyright (c) 2011 Uwe Stuehler <uwe@openbsd.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <sys/types.h>
#include <sys/param.h>

#include <machine/bus.h>

#include <armv7/armv7/armv7var.h>
#include <armv7/sunxi/sunxireg.h>

struct armv7_dev sxia20_devs[] = {

	/* Terminator */
	{ .name = NULL,
	  .unit = 0,
	}
};

void
sxia20_init(void)
{
	armv7_set_devs(sxia20_devs);
}
