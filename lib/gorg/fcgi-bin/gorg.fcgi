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
require 'fcgi'

# Overload read_from_cmdline to avoid crashing when request method
# is neither GET/HEAD/POST. Default behaviour is to read input from
# STDIN. Not really useful when your webserver gets OPTIONS / :-(
class CGI
  module QueryExtension
    def read_from_cmdline
      ''
    end
  end
end


require 'gorg/cgi'

include Gorg

gorgInit
STDERR.close

# Should I commit suicide after a while, life can be so boring!
ak47 = $Config["autoKill"]||0

countReq = 0; t0 = Time.new
# Process CGI requests sent by the fastCGI engine
FCGI.each_cgi do |cgi|
  countReq += 1
  do_CGI(cgi)
  # Is it time to leave?
  # If maximum number of requests has been exceeded _AND_ at least 1 full minute has gone by
  if ak47 > 0 && countReq >= ak47 && Time.new - t0 > 60 then
    info("Autokill : #{countReq} requests have been processed in #{Time.new-t0} seconds")
    Process.kill("USR1",$$)
  else
    # Garbage Collect regularly to help keep memory
    # footprint low enough without costing too much time.
    GC.start if countReq%50==0
  end
end
