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

module Gorg
  Version = "0.6"
end
  
# Some required stuff for gorg
require 'time'

require 'gorg/xsl'
require 'gorg/log'
require 'gorg/cache'
require 'timeout'
require 'cgi'
require 'stringio'
require 'zlib'
require 'ipaddr'


module Gorg

  def xproc(path, params, list=false, printredirect=false)
    # Process file through xslt passing params to the processor
    # path should be the absolute path of the file, i.e. not relative to DocumentRoot
    #
    #    Since 0.4, path can also be a string containing
    #    the actual xml to be processed
    #
    # Use default stylesheet if none can be found in the file
    # Return a list of files read by the processor (useful to do caching) if requested
    #
    # Return an error condition and, hopefully, some useful output
    # Do not raise any exception
    # In most cases, an error will result in no output but
    # the xslt processor can consider some errors as warnings and
    # return the best result it could come up with along with a warning
    # e.g. if a file used in a document() function cannot be found,
    # the xslt processor will return some output and a warning.
    # It's up to the caller to decide whether to use the output or b0rk
    #
    # The return value is an array of 2 to 4 items: [{}, "", [[]], []]
    # 1. hash with error information, its keys are
    # 1.a  "xmlErrCode"  0 is no error, -9999 means an exception has been raised in this block (unlikely),
    #      anything else is an error code (see /usr/include/libxml2/libxml/xmlerror.h)
    # 1.b  "xmlErrLevel" again, from libxml2, 0==OK, 1==Warning, 2==Error, 3==Fatal
    # 1.c  "xmlErrLevel" again, from libxml2, some explanation about what went wrong
    # 2. output from xsltprocessor (or error message from a raised exception)
    # 3. list of files that the xslt processor accessed if the list was requested,
    #    paths are absolute, i.e. not relative to your docroot.
    #    Each entry is an array [access type, path] with access_type being
    #      "r" for read, "w" for written (with exsl:document) or "o" for other (ftp:// or http://)
    # 4. array of CGI::Cookie to be sent back
    #
    # Examples: [{"xmlErrMsg"=>"blah warning blah", "xmlErrCode"=>1509, "xmlErrLevel"=>1}, "This is the best XSLT could do!", nil]
    #           [{"xmlErrCode"=>0}, "Result of XSLT processing. Well done!", ["/etc/xml/catalog","/var/www/localhost/htdocs/doc/en/index.xml","/var/www/localhost/htdocs/dtd/guide.dtd"]]

    xsltproc = Gorg::XSL.new
    xsltproc.xroot = $Config["root"]
    # Grab strings from xsl:message
    xslMessages = []
    # Does the caller want a list of accessed files?
    xsltproc.xtrack = list; filelist = Array.new
    # Process .xml file with stylesheet(s) specified in file, or with default stylesheet
    xsltproc.xml = path
    # Look for stylesheet href (there can be more than one)
    regexp = Regexp.new('<\?xml-stylesheet.*href="([^"]*)".*')
    l = $Config["headXSL"] ; styles = Array.new
    if FileTest.file?(path) then
      # Path is indeed a file name
      IO.foreach(path) { |line|
        styles << $1 if regexp.match(line)
        break if (l-=1) == 0
      }
    else
      # Scan xml for stylesheet names
      path.each { |line| styles << $1 if regexp.match(line) }
    end
    # Use default stylesheet if none were found in the doc
    styles << $Config["defaultXSL"] if styles.length == 0
    # Add params, we expect a hash of {param name => param value,...}
    xsltproc.xparams = params
    # Process through list of stylesheets
    firstErr = {}
    while xsltproc.xsl = styles.shift
      xsltproc.process
      filelist += xsltproc.xfiles if xsltproc.xtrack?
      # Break and raise 301 on redirects
      xsltproc.xmsg.each { |r|
        if r =~ /Redirect=(.+)/ then
          if printredirect then
            STDERR.puts "Location: #{$1}"
          else
            raise Gorg::Status::MovedPermanently.new($1)
          end
        end
      }
      xslMessages += xsltproc.xmsg
      # Remember 1st warning / error
      firstErr = xsltproc.xerr if firstErr["xmlErrLevel"].nil? && xsltproc.xerr["xmlErrLevel"] > 0
      # B0rk on error, an exception should have been raised by the lib, but, er, well, you never know
      break if xsltproc.xerr["xmlErrLevel"] > 1 
      xsltproc.xml = xsltproc.xres
    end
    # Keep 1st warning / error if there has been one
    firstErr = xsltproc.xerr if firstErr["xmlErrLevel"].nil?
    # Return values
    [ firstErr, xsltproc.xres, (filelist.uniq if xsltproc.xtrack?), xslMessages ]
  rescue => ex
    if ex.respond_to?(:errCode) then
      # One of ours (Gorg::Status::HTTPStatus)
      # Propagate exception
      raise
    else
      debug "in xproc exception handler: #{ex.inspect} // #{xsltproc.xerr.inspect}"
      # Return exception message and an error hash as expected from the xslt processor
      # Use error codes that the xslt lib might have returned
      [ if (xsltproc.xerr["xmlErrCode"]||-1) == 0 then
        { "xmlErrMsg"   => ex.to_s,
          "xmlErrCode"  => 9999,
          "xmlErrLevel" => 3
        }
        else
        { "xmlErrMsg"   => xsltproc.xerr["xmlErrMsg"] || ex.to_s,
          "xmlErrCode"  => xsltproc.xerr["xmlErrCode"],
          "xmlErrLevel" => xsltproc.xerr["xmlErrLevel"]
        }
        end ,
        ex.to_s,
        (filelist.uniq if xsltproc.xtrack?)
      ]
    end
  end
  
  # HTTP status codes and html output  
  module Status
    class HTTPStatus < StandardError
      def html(err="")
        <<-EOR
<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<HTML>
<HEAD><TITLE>#{errSts}</TITLE></HEAD>
<BODY>
<H1>#{errLabel}</H1>
<font color="#FF0000">#{err}</font>
<HR>
</BODY>
</HTML>
      EOR
      end
      def errSts
        "#{errCode} #{errLabel}"
      end
      # Default is unknown error
      def errLabel
        "Undefined Error"
      end
      def errCode
        999
      end
      def header
        {'Status' => errSts}
      end
    end
    
    class NotModified < HTTPStatus
      def initialize(stat)
        # 304 needs to send ETag and Last-Modified back
        @mstat=stat
      end
      def header
        {'Last-Modified' => @mstat.mtime.httpdate.dup, 'ETag' => makeETag(@mstat).dup}.merge(super)
      end
      def html
        ""
      end
      def errLabel
        "Not Modified"
      end
      def errCode
        304
      end
    end
    
    class MovedPermanently   < HTTPStatus
      def initialize(loc)
        # 301 needs to send Location:
        @location=loc
      end
      def errLabel
        "Moved Permanently"
      end
      def errCode
        301
      end
      def header
        {'Location' => @location}.merge(super)
      end
      def html
        # RFC says "should" not "must" add a body
        ""
      end
      def html301 # Not used
        <<-EO301
<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>301 Moved Permanently</title>
</head><body>
<h1>Moved Permanently</h1>
<p>The document has moved <a href="#{@location}">here</a>.</p>
</body></html>
        EO301
      end
    end
    
    class Forbidden   < HTTPStatus
      def errLabel
        "Forbidden"
      end
      def errCode
        403
      end
    end
    
    class NotFound    < HTTPStatus 
      def errLabel
        "Not Found"
      end
      def errCode
        404
      end
    end
    
    class NotAllowed    < HTTPStatus 
      def errLabel
        "Method Not Allowed"
      end
      def header
        {'Allow'=>'GET,HEAD'}.merge(super)
      end
      def errCode
        405
      end
    end
    
    class SysError    < HTTPStatus 
      def errLabel
        "Internal Server Error"
      end
      def errCode
        500
      end
    end
  end #Status module
  
  
  def gorgInit
    # Initialize gorg, i.e. read config file, init cache, ...
    # Simply build a hash of params => value in a global variable called $Config
    
    # Set up default values
    $Config = { "AppName" => "gorg",    # Used for syslog entries, please keep 'gorg' (cannot be changed in config file)
                "root" => nil,          # No root dir by default (cgi uses DOCUMENT_ROOT from its environment)
                "port" => 8000,         # Used for stand-alone web server (WEBrick)
                "headXSL" => 12,        # Only read 12 lines in xml files to identify required stylesheets
                "defaultXSL" => nil,    # No default stylesheet, how could I guess?
                "cacheDir" => nil,      # No cache by default. Directory must exist and be writable.
                "cacheTTL" => 0,        # Number of seconds after which a document is considered too old, 0=never
                "cacheSize" => 40,      # in MegaBytes, max size of cache, used when autocleanig
                "zipLevel" => 2,        # Compresion level used for gzip support (HTTP accept_encoding) (0-9, 0=none, 9=max)
                "maxFiles" => 9999,     # Max number of files in a single directory in the cache tree
                "cacheTree" => 0,       # Use same tree as on site in cache, 0 = disabled
                "cacheWash" => 0,       # Clean cache automatically and regularly when a store into the cache occurs. 0 = disabled
                                        #  gorg cleans up if random(param_value) < 10. It will only clean same dir it caches to, not whole tree.
                                        # i.e. a value<=10 means at every call (not a good idea), 100 means once/10 stores, 1000 means once/100 stores
                "logLevel" => 4,        # INFO, be slightly verbose by default (messages go to syslog) OFF, FATAL, ERROR, WARN, INFO, DEBUG = 0, 1, 2, 3, 4, 5
                "passthru" => true,     # Allow return of requested file without processing it if passthru="anything but 0" is passed
                "acceptCookies" =>false,# Allow cookies in & out of transforms
                "linkParam" => "link",  # Pass pathname of requested file in 'link' param to xsl transform
                "HTTP_HOST" => nil,     # Pass host value from HTTP header to xsl transform
                "accessLog" => "syslog",# or a filename or STDERR, used to report hits from WEBrick, not used by cgi's
                "autoKill" => 0,        # Only used by fastCGI, exit after so many requests (0 means no, <=1000 means 1000). Just in case you fear memory leaks.
                "in/out" => [],         # (In/Ex)clude files from indexing
                "mounts" => [],         # Extran mounts for stand-alone server
                "listen" => "127.0.0.1" # Let webrick listen on given IP
            }
    # Always open syslog
    @syslog = Gorg::Log::MySyslog.new($Config["AppName"])
    $Log = Gorg::Log::MyLog.new(@syslog, 5) # Start with max
    
    # Check for config file
    configf = ENV["GORG_CONF"]||"/etc/gorg/gorg.conf"
    raise "Cannot find config file (#{configf})" unless FileTest.file?(configf) and FileTest.readable?(configf)
    file = IO.read(configf)
    parseConfig($Config, file)

    # Init cache
    Cache.init($Config) if $Config["cacheDir"]
    
    # Set requested log level
    $Log.level = $Config["logLevel"]
  rescue
    error("Gorg::init failed: #{$!}")
    STDERR.puts("Gorg::init failed: #{$!}")
    exit(1)
  end

  def scanParams(argv)
    # Scan argv for --param paramName paramValue sequences
    # params are removed from argv
    # Return a hash of {"name" => "value"}
    h = Hash.new
    while idx = argv.index('--param')
      break if argv.length <= idx+2   # We need at least 2 more args after --param
      argv.delete_at(idx)             # Remove --param from argv
      name  = argv.delete_at(idx)     # Remove param name from argv
      value = argv.delete_at(idx)     # Remove param value from argv
      h[name] = value                 # Add entry in result
    end
    
    h if h.length > 0
  end  
  
  private
  def parseConfig(h, config)
    config.each {|line|
      line.strip!
      next if line.length == 0 or line[0,1] == '#' # Skip blank lines and comments
      raise "Invalid Configuration (#{line})" unless line =~ /^([a-zA-Z_]*)\s*=\s*/
      param = $1
      value = $'
      # If value starts with ' or ", it ends with a similar sign and does not accept any in the value, no escaping... We keep it simple
      # otherwise, it ends with EOL or first space
      if value =~ /["'](.*)['"]/ then
        value = $1
      end
      value.strip!
      raise "No value for #{param}" unless value.length > 0
      # Check param / value (only syntactical checks here)
      case param.downcase
      when "root"
       h["root"] = value
      when "port"
       h["port"] = value.to_i
      when "passthru"
       h["passthru"] = value.squeeze != "0"
      when "acceptcookies"
       h["acceptCookies"] = value.squeeze == "1"
      when "linkparam"
       if value =~ /^\s*([a-zA-Z]+)\s*$/ then
         h["linkParam"] = $1
       else
         h["linkParam"] = nil
       end
      when "httphost"
        hosts = value.squeeze(" ")
        case hosts
          when /^0?$/ 
            hh = nil
          when "*"
            hh = ["*"]
          else
            hh = hosts.split(" ")
            # Add IPs
            hosts.split(" ").each { |ho|
              begin
                hh += TCPSocket.gethostbyname(ho)[3..-1] if ho != '*'
              rescue
                # Ignore
                nil
              end
            }
            hh.uniq!
        end
        h["httphost"] = hh
      when "headxsl"
       h["headXSL"] = value.to_i
      when "defaultxsl"
       h["defaultXSL"] = value
      when "cachedir"
       h["cacheDir"] = value
      when "cachettl"
       h["cacheTTL"] = value.to_i
      when "cachesize"
       h["cacheSize"] = value.to_i
      when "maxfiles"
       h["maxFiles"] = value.to_i
      when "cachetree"
       h["cacheTree"] = value.squeeze != "0"
      when "ziplevel"
       if value =~ /^\s*([0-9])\s*$/ then
         h["zipLevel"] = $1.to_i
       else
         h["zipLevel"] = 2
       end
      when "cachewash"
       h["cacheWash"] = value.to_i
      when "loglevel"
       h["logLevel"] = value.to_i
      when "accesslog"
       h["accessLog"] = value
      when "autokill"
       h["autoKill"] = value.to_i
      when "listen"
       begin
         ip = IPAddr.new(value)
         h["listen"] = ip.to_s
       rescue
         h["listen"] = "127.0.0.1"
       end
      when "dbconnect"
        h["dbConnect"] = value
      when "dbuser"
        h["dbUser"] = value
      when "dbpassword"
        h["dbPassword"] = value
      when "exclude"
        h["in/out"] << [false, Regexp.new(value)]
      when "include"
        h["in/out"] << [true,  Regexp.new(value)]
      when "fpath_to_lang"
        h["flang"] = Regexp.new(value)
      when "xpath_to_lang"
        h["xlang"] = value      
      when "mount"
        if value =~ /^([^\s]+)\s+ON\s+(.+)$/i then
          h["mounts"] << [$1, $2]
        end
      else
        raise "Unknown parameter (#{param})"
      end
    }
  rescue
    raise "Could not parse config file: #{$!}"
  end
  
  # Utilities
  def contentType(aMsg)
    # Find the Content-Type=xxx/yyy line in aMsg
    # from the Meta file in the cache
    ct = nil
    aMsg.each { |s|
      if s =~ /^Content-Type:(.+)$/ then
        ct = $1
        break
      end
    }
    ct
  end
  
  def setContentType(data)
    # Set content-type according to x(ht)ml headers
    charset = nil
    if data =~ /^<\?xml .*encoding=['"](.+)['"]/i then
      charset = $1 if $1
      # XML / XHTML
      if data[0..250] =~ /^<\!DOCTYPE\s+html/i then
        # XHTML
        ct = 'application/xhtml+xml'
      else
        # XML
        ct = 'text/xml'
      end
      if charset then
        ct << "; charset=#{charset}"
      end
    elsif data =~ /^<\!DOCTYPE\s+html\sPUBLIC\s(.+DTD XHTML)?/i then
      # (X)HTML
      if $1 then
        # XHTML
        ct = 'application/xhtml+xml'
      else
        # HTML
        ct = 'text/html'
      end
    elsif data =~ /<html/i then
      # HTML
      ct = 'text/html'
    else
      # TXT
      ct = 'text/plain'
    end
    ct
  end

  def makeCookies(aMsg)
    # Make an array of CGI::Cookie objects
    # msg is expected to be an array of strings like 'Set-Cookie(name)value=param'
    # (output by the xsl transform with xsl:message)
    cookies = Hash.new
    aMsg.each { |s|
      if s =~ /^Set-Cookie\(([^\)]+)\)([a-zA-Z0-9_-]+)=(.+)$/ then
        # $1 = cookie name   $2 = key   $3 = value
        if cookies.has_key?($1) then
          cookies[$1] << "#{$2}=#{$3}"
        else
          cookies[$1] = ["#{$2}=#{$3}"]
        end
      end
    }
    if cookies.length > 0 then
      # Make CGI::Cookie objects
      cookies.map { |k,v| 
        CGI::Cookie.new('name' => k, 'value' => v, 'expires' => Time.now + 3600*24*30)
      }
    else
      nil
    end
  end
  
  def cookies_to_params(cookies)
    # Turn array of CGI::Cookie objects into a Hash of key=>value
    # cookies is a hash, forget the keys,
    # each value should be an array of strings, each string should be like 'param=value'
    h = {}
    cookies.values.each { |v|
      if v.class==String and v =~ /^([a-zA-Z0-9_-]+)=(.+)$/ then
        h[$1] = $2
      elsif v.class==Array then
        v.each { |vv|
          if vv.class==String and vv =~ /^([a-zA-Z0-9_-]+)=(.+)$/ then
            h[$1] = $2
          end
        }
      elsif v.class==CGI::Cookie then
        v.value.each { |vv|
          if vv.class==String and vv =~ /^([a-zA-Z0-9_-]+)=(.+)$/ then
            h[$1] = $2
          end
        }
      end
    }
    h
  rescue
    error "Could not parse cookies (#{$!}) "
    {}
  end
  
  def notModified?(fstat, etags, ifmodsince)
    # Decide whether file has been modified according to either etag, last mod timestamp or both
    # If both If-None-Match and If-Modified-Since request header fields are present,
    # they have to be tested both
    res = false
    if fstat then
      a = etags.to_a
      if ifmodsince && etags then
        res = (ifmodsince >= fstat.mtime) && (a.include?(makeETag(fstat)) || a.include?('*'))
      elsif etags
        res = a.include?(makeETag(fstat)) || a.include?('*')
      elsif ifmodsince
        res = ifmodsince >= fstat.mtime
      end
    end
    # Return result
    res
  end  
  
  def split_header_etags(str)
    # Split header values expected as "value1", "value2", ... into an array of strings
    str.scan(/((?:"(?:\\.|[^"])+?"|[^",]+)+)(?:,\s*|\Z)/xn).collect{|v| v[0].strip }
  end
 
  def makeETag(st)
    # Format file stat object into an ETag using its size & mtime
    # Parameter can either be a filename or a stat object
    st = File.stat(st) unless st.respond_to?(:ino)
    sprintf('"%x-%x"', st.size, st.mtime.to_i)
  end
  
  def gzip(data, level)
    gz = ""
    io = StringIO.new(gz)
    gzw = Zlib::GzipWriter.new(io, level)
    gzw.write data
    gzw.close
    gz
  end
  
  def gunzip(data)
    io = StringIO.new(data)
    gzw = Zlib::GzipReader.new(io)
    gunz = gzw.read
    gzw.close
    gunz
  end

end
