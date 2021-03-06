/*	$OpenBSD: parse.y,v 1.11 2016/10/17 16:26:20 reyk Exp $	*/

/*
 * Copyright (c) 2007-2016 Reyk Floeter <reyk@openbsd.org>
 * Copyright (c) 2004, 2005 Esben Norby <norby@openbsd.org>
 * Copyright (c) 2004 Ryan McBride <mcbride@openbsd.org>
 * Copyright (c) 2002, 2003, 2004 Henning Brauer <henning@openbsd.org>
 * Copyright (c) 2001 Markus Friedl.  All rights reserved.
 * Copyright (c) 2001 Daniel Hartmeier.  All rights reserved.
 * Copyright (c) 2001 Theo de Raadt.  All rights reserved.
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

%{
#include <sys/types.h>
#include <sys/queue.h>
#include <sys/socket.h>
#include <sys/uio.h>

#include <machine/vmmvar.h>

#include <net/if.h>
#include <netinet/in.h>
#include <netinet/if_ether.h>

#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <stdarg.h>
#include <string.h>
#include <ctype.h>
#include <netdb.h>
#include <util.h>
#include <errno.h>
#include <err.h>

#include "proc.h"
#include "vmd.h"

TAILQ_HEAD(files, file)		 files = TAILQ_HEAD_INITIALIZER(files);
static struct file {
	TAILQ_ENTRY(file)	 entry;
	FILE			*stream;
	char			*name;
	int			 lineno;
	int			 errors;
} *file, *topfile;
struct file	*pushfile(const char *, int);
int		 popfile(void);
int		 yyparse(void);
int		 yylex(void);
int		 yyerror(const char *, ...)
    __attribute__((__format__ (printf, 1, 2)))
    __attribute__((__nonnull__ (1)));
int		 kw_cmp(const void *, const void *);
int		 lookup(char *);
int		 lgetc(int);
int		 lungetc(int);
int		 findeol(void);

TAILQ_HEAD(symhead, sym)	 symhead = TAILQ_HEAD_INITIALIZER(symhead);
struct sym {
	TAILQ_ENTRY(sym)	 entry;
	int			 used;
	int			 persist;
	char			*nam;
	char			*val;
};
int		 symset(const char *, const char *, int);
char		*symget(const char *);

ssize_t		 parse_size(char *, int64_t);
int		 parse_disk(char *);

static struct vmop_create_params vmc;
static struct vm_create_params	*vcp;
static struct vmd_switch	*vsw;
static struct vmd_if		*vif;
static unsigned int		 vsw_unit;
static char			 vsw_type[IF_NAMESIZE];
static int			 vcp_disable;
static size_t			 vcp_nnics;
static int			 errors;
extern struct vmd		*env;
extern const char		*vmd_descsw[];

typedef struct {
	union {
		uint8_t		 lladdr[ETHER_ADDR_LEN];
		int64_t		 number;
		char		*string;
	} v;
	int lineno;
} YYSTYPE;

%}


%token	INCLUDE ERROR
%token	ADD DISK DOWN GROUP INTERFACE NIFS PATH SIZE SWITCH UP VMID
%token	ENABLE DISABLE VM KERNEL LLADDR MEMORY
%token	<v.string>	STRING
%token  <v.number>	NUMBER
%type	<v.number>	disable
%type	<v.number>	updown
%type	<v.lladdr>	lladdr
%type	<v.string>	string
%type	<v.string>	optstring

%%

grammar		: /* empty */
		| grammar include '\n'
		| grammar '\n'
		| grammar varset '\n'
		| grammar switch '\n'
		| grammar vm '\n'
		| grammar error '\n'		{ file->errors++; }
		;

include		: INCLUDE string		{
			struct file	*nfile;

			if ((nfile = pushfile($2, 0)) == NULL) {
				yyerror("failed to include file %s", $2);
				free($2);
				YYERROR;
			}
			free($2);

			file = nfile;
			lungetc('\n');
		}
		;

varset		: STRING '=' STRING		{
			char *s = $1;
			while (*s++) {
				if (isspace((unsigned char)*s)) {
					yyerror("macro name cannot contain "
					    "whitespace");
					YYERROR;
				}
			}
			if (symset($1, $3, 0) == -1)
				fatalx("cannot store variable");
			free($1);
			free($3);
		}
		;

switch		: SWITCH string			{
			if ((vsw = calloc(1, sizeof(*vsw))) == NULL)
				fatal("could not allocate switch");

			vsw->sw_id = env->vmd_nswitches + 1;
			vsw->sw_name = $2;
			vsw->sw_flags = IFF_UP;
			snprintf(vsw->sw_ifname, sizeof(vsw->sw_ifname),
			    "%s%u", vsw_type, vsw_unit++);
			TAILQ_INIT(&vsw->sw_ifs);

			vcp_disable = 0;
		} '{' optnl switch_opts_l '}'	{
			TAILQ_INSERT_TAIL(env->vmd_switches, vsw, sw_entry);
			env->vmd_nswitches++;

			if (vcp_disable) {
				log_debug("%s:%d: switch \"%s\""
				    " skipped (disabled)",
				    file->name, yylval.lineno, vsw->sw_name);
			} else if (!env->vmd_noaction) {
				/*
				 * XXX Configure the switch right away -
				 * XXX this should be done after parsing
				 * XXX the configuration.
				 */
				if (vm_priv_brconfig(&env->vmd_ps, vsw) == -1) {
					log_warn("%s:%d: switch \"%s\" failed",
					    file->name, yylval.lineno,
					    vsw->sw_name);
					YYERROR;
				} else {
					log_debug("%s:%d: switch \"%s\""
					    " configured",
					    file->name, yylval.lineno,
					    vsw->sw_name);
				}
			}
		}
		;

switch_opts_l	: switch_opts_l switch_opts nl
		| switch_opts optnl
		;

switch_opts	: disable			{
			vcp_disable = $1;
		}
		| ADD string			{
			char		type[IF_NAMESIZE];

			if ((vif = calloc(1, sizeof(*vif))) == NULL)
				fatal("could not allocate interface");

			if (priv_getiftype($2, type, NULL) == -1) {
				yyerror("invalid interface: %s", $2);
				free($2);
				YYERROR;
			}
			vif->vif_name = $2;

			TAILQ_INSERT_TAIL(&vsw->sw_ifs, vif, vif_entry);
		}
		| GROUP string			{
			if (priv_validgroup($2) == -1) {
				yyerror("invalid group name: %s", $2);
				free($2);
				YYERROR;
			}
			vsw->sw_group = $2;
		}
		| INTERFACE string		{
			if (priv_getiftype($2, vsw_type, &vsw_unit) == -1 ||
			    priv_findname(vsw_type, vmd_descsw) == -1) {
				yyerror("invalid switch interface: %s", $2);
				free($2);
				YYERROR;
			}
			vsw_unit++;

			if (strlcpy(vsw->sw_ifname, $2,
			    sizeof(vsw->sw_ifname)) >= sizeof(vsw->sw_ifname)) {
				yyerror("switch interface too long: %s", $2);
				free($2);
				YYERROR;
			}
			free($2);
		}
		| updown			{
			if ($1)
				vsw->sw_flags |= IFF_UP;
			else
				vsw->sw_flags &= ~IFF_UP;
		}
		;

vm		: VM string			{
			unsigned int	 i;

			memset(&vmc, 0, sizeof(vmc));
			vcp = &vmc.vmc_params;
			vcp_disable = 0;
			vcp_nnics = 0;

			for (i = 0; i < VMM_MAX_NICS_PER_VM; i++) {
				/* Set the interface to UP by default */
				vmc.vmc_ifflags[i] |= IFF_UP;
			}

			if (strlcpy(vcp->vcp_name, $2, sizeof(vcp->vcp_name)) >=
			    sizeof(vcp->vcp_name)) {
				yyerror("vm name too long");
				YYERROR;
			}
		} '{' optnl vm_opts_l '}'	{
			int ret;

			/* configured interfaces vs. number of interfaces */
			if (vcp_nnics > vcp->vcp_nnics)
				vcp->vcp_nnics = vcp_nnics;

			if (vcp_disable) {
				log_debug("%s:%d: vm \"%s\" skipped (disabled)",
				    file->name, yylval.lineno, vcp->vcp_name);
			} else if (!env->vmd_noaction) {
				/*
				 * XXX Start the vm right away -
				 * XXX this should be done after parsing
				 * XXX the configuration.
				 */
				ret = config_getvm(&env->vmd_ps, &vmc, -1, -1);
				if (ret == -1 && errno == EALREADY) {
					log_debug("%s:%d: vm \"%s\""
					    " skipped (running)",
					    file->name, yylval.lineno,
					    vcp->vcp_name);
				} else if (ret == -1) {
					log_warn("%s:%d: vm \"%s\" failed",
					    file->name, yylval.lineno,
					    vcp->vcp_name);
					YYERROR;
				} else {
					log_debug("%s:%d: vm \"%s\" enabled",
					    file->name, yylval.lineno,
					    vcp->vcp_name);
				}
			}
		}
		;

vm_opts_l	: vm_opts_l vm_opts nl
		| vm_opts optnl
		;

vm_opts		: disable			{
			vcp_disable = $1;
		}
		| DISK string			{
			if (parse_disk($2) != 0) {
				yyerror("failed to parse disks: %s", $2);
				free($2);
				YYERROR;
			}
			free($2);
		}
		| INTERFACE optstring iface_opts_o {
			unsigned int	i;
			char		type[IF_NAMESIZE];

			i = vcp_nnics;
			if (++vcp_nnics > VMM_MAX_NICS_PER_VM) {
				yyerror("too many interfaces: %zu", vcp_nnics);
				free($2);
				YYERROR;
			}

			if ($2 != NULL) {
				if (strcmp($2, "tap") != 0 &&
				    (priv_getiftype($2, type, NULL) == -1 ||
				    strcmp(type, "tap") != 0)) {
					yyerror("invalid interface: %s", $2);
					free($2);
					YYERROR;
				}

				if (strlcpy(vmc.vmc_ifnames[i], $2,
				    sizeof(vmc.vmc_ifnames[i])) >=
				    sizeof(vmc.vmc_ifnames[i])) {
					yyerror("interface name too long: %s",
					    $2);
					free($2);
					YYERROR;
				}
			}
			free($2);
		}
		| KERNEL string			{
			if (vcp->vcp_kernel[0] != '\0') {
				yyerror("kernel specified more than once");
				free($2);
				YYERROR;

			}
			if (strlcpy(vcp->vcp_kernel, $2,
			    sizeof(vcp->vcp_kernel)) >=
			    sizeof(vcp->vcp_kernel)) {
				yyerror("kernel name too long");
				free($2);
				YYERROR;
			}
			free($2);
		}
		| NIFS NUMBER			{
			if (vcp->vcp_nnics != 0) {
				yyerror("interfaces specified more than once");
				YYERROR;
			}
			if ($2 < 0 || $2 > VMM_MAX_NICS_PER_VM) {
				yyerror("too many interfaces: %lld", $2);
				YYERROR;
			}
			vcp->vcp_nnics = (size_t)$2;
		}
		| MEMORY NUMBER			{
			ssize_t	 res;
			if (vcp->vcp_memranges[0].vmr_size != 0) {
				yyerror("memory specified more than once");
				YYERROR;
			}
			if ((res = parse_size(NULL, $2)) == -1) {
				yyerror("failed to parse size: %lld", $2);
				YYERROR;
			}
			vcp->vcp_memranges[0].vmr_size = (size_t)res;
		}
		| MEMORY STRING			{
			ssize_t	 res;
			if (vcp->vcp_memranges[0].vmr_size != 0) {
				yyerror("argument specified more than once");
				free($2);
				YYERROR;
			}
			if ((res = parse_size($2, 0)) == -1) {
				yyerror("failed to parse size: %s", $2);
				free($2);
				YYERROR;
			}
			vcp->vcp_memranges[0].vmr_size = (size_t)res;
		}
		;

iface_opts_o	: '{' optnl iface_opts_l '}'
		| /* empty */
		;

iface_opts_l	: iface_opts_l iface_opts optnl
		| iface_opts optnl
		;

iface_opts	: SWITCH string			{
			unsigned int	i = vcp_nnics;

			/* No need to check if the switch exists */
			if (strlcpy(vmc.vmc_ifswitch[i], $2,
			    sizeof(vmc.vmc_ifswitch[i])) >=
			    sizeof(vmc.vmc_ifswitch[i])) {
				yyerror("switch name too long: %s", $2);
				free($2);
				YYERROR;
			}
			free($2);
		}
		| GROUP string			{
			unsigned int	i = vcp_nnics;

			if (priv_validgroup($2) == -1) {
				yyerror("invalid group name: %s", $2);
				free($2);
				YYERROR;
			}

			/* No need to check if the group exists */
			(void)strlcpy(vmc.vmc_ifgroup[i], $2,
			    sizeof(vmc.vmc_ifgroup[i]));
			free($2);
		}
		| LLADDR lladdr			{
			memcpy(vcp->vcp_macs[vcp_nnics], $2, ETHER_ADDR_LEN);
		}
		| updown			{
			if ($1)
				vmc.vmc_ifflags[vcp_nnics] |= IFF_UP;
			else
				vmc.vmc_ifflags[vcp_nnics] &= ~IFF_UP;
		}
		;

optstring	: STRING			{ $$ = $1; }
		| /* empty */			{ $$ = NULL; }
		;

string		: STRING string			{
			if (asprintf(&$$, "%s%s", $1, $2) == -1)
				fatal("asprintf string");
			free($1);
			free($2);
		}
		| STRING
		;

lladdr		: STRING			{
			struct ether_addr *ea;

			if ((ea = ether_aton($1)) == NULL) {
				yyerror("invalid address: %s\n", $1);
				free($1);
				YYERROR;
			}
			free($1);

			memcpy($$, ea, ETHER_ADDR_LEN);
		}
		;

updown		: UP				{ $$ = 1; }
		| DOWN				{ $$ = 0; }
		;

disable		: ENABLE			{ $$ = 0; }
		| DISABLE			{ $$ = 1; }
		;

optnl		: '\n' optnl
		|
		;

nl		: '\n' optnl
		;

%%

struct keywords {
	const char	*k_name;
	int		 k_val;
};

int
yyerror(const char *fmt, ...)
{
	va_list		 ap;
	char		*msg;

	file->errors++;
	va_start(ap, fmt);
	if (vasprintf(&msg, fmt, ap) == -1)
		fatal("yyerror vasprintf");
	va_end(ap);
	log_warnx("%s:%d: %s", file->name, yylval.lineno, msg);
	free(msg);
	return (0);
}

int
kw_cmp(const void *k, const void *e)
{
	return (strcmp(k, ((const struct keywords *)e)->k_name));
}

int
lookup(char *s)
{
	/* this has to be sorted always */
	static const struct keywords keywords[] = {
		{ "add",		ADD },
		{ "disable",		DISABLE },
		{ "disk",		DISK },
		{ "down",		DOWN },
		{ "enable",		ENABLE },
		{ "group",		GROUP },
		{ "id",			VMID },
		{ "include",		INCLUDE },
		{ "interface",		INTERFACE },
		{ "interfaces",		NIFS },
		{ "kernel",		KERNEL },
		{ "lladdr",		LLADDR },
		{ "memory",		MEMORY },
		{ "size",		SIZE },
		{ "switch",		SWITCH },
		{ "up",			UP },
		{ "vm",			VM }
	};
	const struct keywords	*p;

	p = bsearch(s, keywords, sizeof(keywords)/sizeof(keywords[0]),
	    sizeof(keywords[0]), kw_cmp);

	if (p)
		return (p->k_val);
	else
		return (STRING);
}

#define MAXPUSHBACK	128

u_char	*parsebuf;
int	 parseindex;
u_char	 pushback_buffer[MAXPUSHBACK];
int	 pushback_index = 0;

int
lgetc(int quotec)
{
	int		c, next;

	if (parsebuf) {
		/* Read character from the parsebuffer instead of input. */
		if (parseindex >= 0) {
			c = parsebuf[parseindex++];
			if (c != '\0')
				return (c);
			parsebuf = NULL;
		} else
			parseindex++;
	}

	if (pushback_index)
		return (pushback_buffer[--pushback_index]);

	if (quotec) {
		if ((c = getc(file->stream)) == EOF) {
			yyerror("reached end of file while parsing "
			    "quoted string");
			if (file == topfile || popfile() == EOF)
				return (EOF);
			return (quotec);
		}
		return (c);
	}

	while ((c = getc(file->stream)) == '\\') {
		next = getc(file->stream);
		if (next != '\n') {
			c = next;
			break;
		}
		yylval.lineno = file->lineno;
		file->lineno++;
	}
	if (c == '\t' || c == ' ') {
		/* Compress blanks to a single space. */
		do {
			c = getc(file->stream);
		} while (c == '\t' || c == ' ');
		ungetc(c, file->stream);
		c = ' ';
	}

	while (c == EOF) {
		if (file == topfile || popfile() == EOF)
			return (EOF);
		c = getc(file->stream);
	}
	return (c);
}

int
lungetc(int c)
{
	if (c == EOF)
		return (EOF);
	if (parsebuf) {
		parseindex--;
		if (parseindex >= 0)
			return (c);
	}
	if (pushback_index < MAXPUSHBACK-1)
		return (pushback_buffer[pushback_index++] = c);
	else
		return (EOF);
}

int
findeol(void)
{
	int	c;

	parsebuf = NULL;

	/* skip to either EOF or the first real EOL */
	while (1) {
		if (pushback_index)
			c = pushback_buffer[--pushback_index];
		else
			c = lgetc(0);
		if (c == '\n') {
			file->lineno++;
			break;
		}
		if (c == EOF)
			break;
	}
	return (ERROR);
}

int
yylex(void)
{
	u_char	 buf[8096];
	u_char	*p, *val;
	int	 quotec, next, c;
	int	 token;

top:
	p = buf;
	while ((c = lgetc(0)) == ' ' || c == '\t')
		; /* nothing */

	yylval.lineno = file->lineno;
	if (c == '#')
		while ((c = lgetc(0)) != '\n' && c != EOF)
			; /* nothing */
	if (c == '$' && parsebuf == NULL) {
		while (1) {
			if ((c = lgetc(0)) == EOF)
				return (0);

			if (p + 1 >= buf + sizeof(buf) - 1) {
				yyerror("string too long");
				return (findeol());
			}
			if (isalnum(c) || c == '_') {
				*p++ = c;
				continue;
			}
			*p = '\0';
			lungetc(c);
			break;
		}
		val = symget(buf);
		if (val == NULL) {
			yyerror("macro '%s' not defined", buf);
			return (findeol());
		}
		parsebuf = val;
		parseindex = 0;
		goto top;
	}

	switch (c) {
	case '\'':
	case '"':
		quotec = c;
		while (1) {
			if ((c = lgetc(quotec)) == EOF)
				return (0);
			if (c == '\n') {
				file->lineno++;
				continue;
			} else if (c == '\\') {
				if ((next = lgetc(quotec)) == EOF)
					return (0);
				if (next == quotec || c == ' ' || c == '\t')
					c = next;
				else if (next == '\n') {
					file->lineno++;
					continue;
				} else
					lungetc(next);
			} else if (c == quotec) {
				*p = '\0';
				break;
			} else if (c == '\0') {
				yyerror("syntax error");
				return (findeol());
			}
			if (p + 1 >= buf + sizeof(buf) - 1) {
				yyerror("string too long");
				return (findeol());
			}
			*p++ = c;
		}
		yylval.v.string = strdup(buf);
		if (yylval.v.string == NULL)
			fatal("yylex: strdup");
		return (STRING);
	}

#define allowed_to_end_number(x) \
	(isspace(x) || x == ')' || x ==',' || x == '/' || x == '}' || x == '=')

	if (c == '-' || isdigit(c)) {
		do {
			*p++ = c;
			if ((unsigned)(p-buf) >= sizeof(buf)) {
				yyerror("string too long");
				return (findeol());
			}
		} while ((c = lgetc(0)) != EOF && isdigit(c));
		lungetc(c);
		if (p == buf + 1 && buf[0] == '-')
			goto nodigits;
		if (c == EOF || allowed_to_end_number(c)) {
			const char *errstr = NULL;

			*p = '\0';
			yylval.v.number = strtonum(buf, LLONG_MIN,
			    LLONG_MAX, &errstr);
			if (errstr) {
				yyerror("\"%s\" invalid number: %s",
				    buf, errstr);
				return (findeol());
			}
			return (NUMBER);
		} else {
nodigits:
			while (p > buf + 1)
				lungetc(*--p);
			c = *--p;
			if (c == '-')
				return (c);
		}
	}

#define allowed_in_string(x) \
	(isalnum(x) || (ispunct(x) && x != '(' && x != ')' && \
	x != '{' && x != '}' && \
	x != '!' && x != '=' && x != '#' && \
	x != ','))

	if (isalnum(c) || c == ':' || c == '_' || c == '/') {
		do {
			*p++ = c;
			if ((unsigned)(p-buf) >= sizeof(buf)) {
				yyerror("string too long");
				return (findeol());
			}
		} while ((c = lgetc(0)) != EOF && (allowed_in_string(c)));
		lungetc(c);
		*p = '\0';
		if ((token = lookup(buf)) == STRING)
			if ((yylval.v.string = strdup(buf)) == NULL)
				fatal("yylex: strdup");
		return (token);
	}
	if (c == '\n') {
		yylval.lineno = file->lineno;
		file->lineno++;
	}
	if (c == EOF)
		return (0);
	return (c);
}

struct file *
pushfile(const char *name, int secret)
{
	struct file	*nfile;

	if ((nfile = calloc(1, sizeof(struct file))) == NULL) {
		log_warn("malloc");
		return (NULL);
	}
	if ((nfile->name = strdup(name)) == NULL) {
		log_warn("malloc");
		free(nfile);
		return (NULL);
	}
	if ((nfile->stream = fopen(nfile->name, "r")) == NULL) {
		free(nfile->name);
		free(nfile);
		return (NULL);
	}
	nfile->lineno = 1;
	TAILQ_INSERT_TAIL(&files, nfile, entry);
	return (nfile);
}

int
popfile(void)
{
	struct file	*prev;

	if ((prev = TAILQ_PREV(file, files, entry)) != NULL)
		prev->errors += file->errors;

	TAILQ_REMOVE(&files, file, entry);
	fclose(file->stream);
	free(file->name);
	free(file);
	file = prev;
	return (file ? 0 : EOF);
}

int
parse_config(const char *filename)
{
	struct sym	*sym, *next;

	if ((file = pushfile(filename, 0)) == NULL) {
		log_warn("failed to open %s", filename);
		return (0);
	}
	topfile = file;
	setservent(1);

	/* Set the default switch type */
	(void)strlcpy(vsw_type, VMD_SWITCH_TYPE, sizeof(vsw_type));

	yyparse();
	errors = file->errors;
	popfile();

	endservent();

	/* Free macros and check which have not been used. */
	for (sym = TAILQ_FIRST(&symhead); sym != NULL; sym = next) {
		next = TAILQ_NEXT(sym, entry);
		if (!sym->used)
			fprintf(stderr, "warning: macro '%s' not "
			    "used\n", sym->nam);
		if (!sym->persist) {
			free(sym->nam);
			free(sym->val);
			TAILQ_REMOVE(&symhead, sym, entry);
			free(sym);
		}
	}

	if (errors)
		return (-1);

	return (0);
}

int
symset(const char *nam, const char *val, int persist)
{
	struct sym	*sym;

	for (sym = TAILQ_FIRST(&symhead); sym && strcmp(nam, sym->nam);
	    sym = TAILQ_NEXT(sym, entry))
		;	/* nothing */

	if (sym != NULL) {
		if (sym->persist == 1)
			return (0);
		else {
			free(sym->nam);
			free(sym->val);
			TAILQ_REMOVE(&symhead, sym, entry);
			free(sym);
		}
	}
	if ((sym = calloc(1, sizeof(*sym))) == NULL)
		return (-1);

	sym->nam = strdup(nam);
	if (sym->nam == NULL) {
		free(sym);
		return (-1);
	}
	sym->val = strdup(val);
	if (sym->val == NULL) {
		free(sym->nam);
		free(sym);
		return (-1);
	}
	sym->used = 0;
	sym->persist = persist;
	TAILQ_INSERT_TAIL(&symhead, sym, entry);
	return (0);
}

int
cmdline_symset(char *s)
{
	char	*sym, *val;
	int	ret;
	size_t	len;

	if ((val = strrchr(s, '=')) == NULL)
		return (-1);

	len = (val - s) + 1;
	if ((sym = malloc(len)) == NULL)
		fatal("cmdline_symset: malloc");

	(void)strlcpy(sym, s, len);

	ret = symset(sym, val + 1, 1);
	free(sym);

	return (ret);
}

char *
symget(const char *nam)
{
	struct sym	*sym;

	TAILQ_FOREACH(sym, &symhead, entry)
		if (strcmp(nam, sym->nam) == 0) {
			sym->used = 1;
			return (sym->val);
		}
	return (NULL);
}

ssize_t
parse_size(char *word, int64_t val)
{
	ssize_t		 size;
	long long	 res;

	if (word != NULL) {
		if (scan_scaled(word, &res) != 0) {
			log_warn("invalid size: %s", word);
			return (-1);
		}
		val = (int64_t)res;
	}

	if (val < (1024 * 1024)) {
		log_warnx("size must be at least one megabyte");
		return (-1);
	} else
		size = val / 1024 / 1024;

	if ((size * 1024 * 1024) != val)
		log_warnx("size rounded to %zd megabytes", size);

	return ((ssize_t)size);
}

int
parse_disk(char *word)
{
	if (vcp->vcp_ndisks >= VMM_MAX_DISKS_PER_VM) {
		log_warnx("too many disks");
		return (-1);
	}

	if (strlcpy(vcp->vcp_disks[vcp->vcp_ndisks], word,
	    VMM_MAX_PATH_DISK) >= VMM_MAX_PATH_DISK) {
		log_warnx("disk path too long");
		return (-1);
	}

	vcp->vcp_ndisks++;

	return (0);
}
