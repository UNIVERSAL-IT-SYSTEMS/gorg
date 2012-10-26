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

# Write logging info for our little gorg

require 'syslog'
require 'webrick/log'

module Gorg
  # Make log functions available as if we were inside a log instance
  # If no $Log global variable has been initialized, do nothing
  def fatal(msg) $Log.fatal(msg) if $Log; end
  def error(msg) $Log.error(msg) if $Log; end
  def warn(msg)  $Log.warn(msg)  if $Log; end
  def info(msg)  $Log.info(msg)  if $Log; end
  def debug(msg) $Log.debug(msg) if $Log; end

 module Log
 
  class MyLog < WEBrick::BasicLog
    # Interface to WEBrick log system
    # Not much to add at this time ;-)
  end
  
  class MySyslog
    # Interface to syslog
    def initialize(appname)
      # Open syslog if not already done (only one open is allowed)
      @@syslog = Syslog.open(appname) unless defined?(@@syslog)
      # Make sure messages get through (WEBrick has its own filter)
      @@syslog.mask = Syslog::LOG_UPTO(Syslog::LOG_ERR)
    end
    
    def <<(str)
      # WEBrick's logging requires the << method
      # Just forward string to syslog
      @@syslog.err(str)
    end
  end
 end
end
