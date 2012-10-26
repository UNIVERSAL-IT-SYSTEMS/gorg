#! /usr/bin/ruby

###   Copyright 2004,   Xavier Neys   (neysx@gentoo.org)
# #
# #   This file is part of gorg.
# #
# #   gorg is free software; you can redistribute it and/or modify
# #   it under the terms of the GNU General Public License as published by
# #   the Free Software Foundation; either version 2 of the License, or
# #   (at your option) any later version.
# #
# #   gorg is distributed in the hope that it will be useful,
# #   but WITHOUT ANY WARRANTY; without even the implied warranty of
# #   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# #   GNU General Public License for more details.
# #
# #   You should have received a copy of the GNU General Public License
# #   along with gorg; if not, write to the Free Software
###   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA


require 'cgi'
require 'gorg/search'

# Make CGI's env public to get access to REQUEST_URI and DOCUMENT_ROOT
class CGI
  public :env_table
end

include Gorg

# Config file is named in env var. GORG_CONF, or possibly REDIRECT_GORG_CONF
# ENV["PATH"] is used as a dirty hackish workaround a limitation of
# webrick's cgi handler: environment variables can't be passed to cgi's
# (REDIRECT_)GORG_CONF should be defined when running cgi's under apache
ENV["GORG_CONF"] = ENV["GORG_CONF"]||ENV["REDIRECT_GORG_CONF"]||ENV["PATH"]

gorgInit
cgi = CGI.new

# Params
#
# l = language code, no param will default to en, empty param defaults to any)
# q = query string
# p = page number in search result (0 < p < 1e6)
# s = page size (9 < p < 120)
# b = boolean search (y|Y|1 means yes, anything else no)

gs = GDig::GSearch.new
gs.do_CGI(cgi)
