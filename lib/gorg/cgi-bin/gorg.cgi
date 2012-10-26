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
# #   along with Foobar; if not, write to the Free Software
###   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

require 'cgi'

require 'gorg/cgi'

if ARGV.length == 1  and  ['-F', '--filter'].include?(ARGV[0]) then
  # cgi does not accept any params like gorg, 
  # Only test on -F or --filter being there and nothing else
  do_Filter unless STDIN.tty?
else
  # Make CGI's env public to get access to REQUEST_URI and DOCUMENT_ROOT
  class CGI
   public :env_table
  end

  include Gorg

  # Config file is named in env var. GORG_CONF, or possibly REDIRECT_GORG_CONF
  ENV["GORG_CONF"] = ENV["GORG_CONF"]||ENV["REDIRECT_GORG_CONF"]

  gorgInit
  STDERR.close

  cgi = CGI.new
  do_CGI(cgi)
end
