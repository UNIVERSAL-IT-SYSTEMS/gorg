/*
    Copyright 2004,   Xavier Neys   (neysx@gentoo.org)

    This file is part of gorg.

    gorg is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    gorg is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Foobar; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*/

#ifndef __XSL_H__
#define __XSL_H__

#include <sys/stat.h>
#include <assert.h>
#include <unistd.h>
#include <ruby.h>
#include <libxslt/xslt.h>
#include <libexslt/exslt.h>
#include <libxslt/xsltInternals.h>
#include <libxslt/extra.h>
#include <libxslt/xsltutils.h>
#include <libxslt/transform.h>

typedef struct S_cleanup
{
  char *params;
  xmlDocPtr docxml, docxsl, docres;
  xsltStylesheetPtr xsl;
  xmlChar *docstr;
}
s_cleanup;

#define XSL_VERSION  "0.1"

#endif
