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

# Run the stand-alone webserver and serve gentoo.org

require 'gorg/base'
require 'webrick'
require 'cgi'

class GentooServlet < WEBrick::HTTPServlet::FileHandler
  include Gorg
  
  def do_GET(req, res)
    hit = "#{$Config["root"]}#{req.path}"
    cacheName = req.path
    if FileTest.directory?(hit) and FileTest.exist?(hit+"/index.xml") then
      # Use $URI/index.xml for directories that have an index.xml file
      hit << "/index.xml"
      cacheName << "/index.xml"
    end
    hit.squeeze!('/')
    cacheName.squeeze!('/')
    if FileTest.directory?(hit) then
      super # Use default FileHandler for directories that have no index.xml
    else
      if hit !~ /\.(xml)|(rdf)|(rss)$/ then
        super # Use default FileHandler if not an xml file
      else
        if not FileTest.exist?(hit) then
          super # Use default FileHandler to handle 404 (file does not exist)
        else
          # Parse If-None-Match and If-Modified-Since request header fields if any
          ims=inm=nil
          begin
            ims = Time.parse(req['if-modified-since']) if req['if-modified-since']
            inm = split_header_etags(req['if-none-match']) if req['if-none-match']
          rescue
            # Just ignore ill-formated data
            nil
          end
          begin
            res['Charset'] = 'UTF-8'
            # Process xml file or return xml file if passthru=1
            if $Config['passthru'] && req.query && req.query["passthru"] && req.query["passthru"] != "0" then
              # passthru allowed by config and requested by visitor, return file as text/plain
              mstat = File.stat(hit)
              raise Gorg::Status::NotModified.new(mstat) if notModified?(mstat, inm, ims)
              debug("Passthru granted for #{hit}")
              body = IO.read(hit)
              # If client accepts gzip encoding and we support it, return gzipped file
              if $Config["zipLevel"] > 0 and (req.accept_encoding.include?("gzip") or req.accept_encoding.include?("x-gzip")) then
                res.body = gzip(body, $Config["zipLevel"])
                res['Content-Encoding'] = "gzip"
                res['Vary'] = "Accept-Encoding"
              else
                res.body = body
              end
              res['Content-Type'] = 'text/plain'
            else
              query_params = req.query.dup
              # Get cookies and add them to the parameters
              if $Config["acceptCookies"] then
                # We need CGI:Cookie objects to be compatible with our cgi modules (stupid WEBrick)
                ck = req.raw_header.find{|l| l =~ /^cookie: /i}
                if ck then
                  query_params.merge!(cookies_to_params(CGI::Cookie.parse($'.strip)))
                  debug "query params are " + query_params.inspect
                end
              end
              if $Config["httphost"] then
                # Add HTTP_HOST to stylesheet params
                query_params["httphost"] = if $Config["httphost"][0] == '*' then
                                             req.host||""
                                           elsif $Config["httphost"].include?('*') then
                                             $Config["httphost"][0]
                                           elsif $Config["httphost"].include?(req.host) then
                                             $Config["httphost"][0]
                                           else
                                             req.host||""
                                           end
              end

              bodyZ = nil
              body, mstat, extrameta = Gorg::Cache.hit(cacheName, query_params, inm, ims)
              if body.nil? then
                xml_query = query_params.dup
                if $Config["linkParam"] then
                  xml_query[$Config["linkParam"]] = req.path
                end
                # Cache miss, process file and cache result
                err, body, filelist, extrameta = xproc(hit, xml_query, true)
                warn("#{err.collect{|e|e.join(':')}.join('; ')}") if err["xmlErrLevel"] == 1
                error("#{err.collect{|e|e.join(':')}.join('; ')}") if err["xmlErrLevel"] > 1
                # Display error message if any, just like the cgi/fcgi versions
                raise ("#{err.collect{|e|e.join(':')}.join('<br/>')}") if err["xmlErrLevel"] > 0
                # Cache output
                mstat, bodyZ = Gorg::Cache.store(body, cacheName, query_params, filelist, extrameta)
              else
                if $Config["zipLevel"] > 0 then
                  bodyZ = body
                  body = nil
                end
              end
              # If client accepts gzip encoding and we support it, return gzipped file
              if bodyZ and $Config["zipLevel"] > 0 and (req.accept_encoding.include?("gzip") or req.accept_encoding.include?("x-gzip")) then
                res.body = bodyZ
                res['Content-Encoding'] = "gzip"
                res['Vary'] = "Accept-Encoding"
              else
                if body then
                  res.body = body
                else
                  # We need to unzip bodyZ into body, i.e. we cached zipped data but client does not support gzip
                  res.body = gunzip(bodyZ)
                end
              end
              # Add cookies to http header
              cookies = makeCookies(extrameta)
              if cookies then
                cookies.each{|c| res.cookies << c.to_s}
              end
              # Add Content-Type to header
              ct = contentType(extrameta).split(';')[0]
              if ct then
                # Turn application/xhtml+xml into text/html if browser does not accept it
                if req.accept.to_s !~ /application\/xhtml\+xml/ and ct =~ /application\/xhtml\+xml(.*)$/ then
                  res['Content-Type'] = "text/html#{$1}"
                else
                  res['Content-Type'] = ct
                end
              else
                res['Content-Type'] = 'text/plain'
              end
            end
            if mstat then
              res['ETag'] = makeETag(mstat)
              res['Last-Modified'] = mstat.mtime.httpdate
            end
          rescue => ex
            if ex.respond_to?(:errCode) then
              # One of ours (Gorg::Status::HTTPStatus)
              res.body = ex.html
              res.status = ex.errCode
              ex.header.each {|k,v| res[k]=v unless k =~ /status|cookie/i}
            else
              # Some ruby exceptions occurred, make it a syserr
              syserr = Gorg::Status::SysError.new
              res.body = syserr.html(ex)
              res.status = syserr.errCode
            end
          end
        end
      end
    end
  end
end

###
#|#  Start Here 
###

def www
  # Log accesses to either stderr, syslog or a file
  if $Config["accessLog"] == "syslog"
    # Use syslog again, use our own format based on default but without timestamp
    access_log = [ [ @syslog, "HIT   %h \"%r\" %s %b" ] ]
    STDERR.close
  elsif $Config["accessLog"] == "stderr"
    # Use syslog again, use our own format based on default but without timestamp
    access_log = [ [ STDERR, "HIT   %h \"%r\" %s %b" ] ]
  else
    # Open file and use it, if it's not writable, tough!
    access_log_stream = File.open($Config["accessLog"], "a")
    access_log = [ [ access_log_stream, WEBrick::AccessLog::COMBINED_LOG_FORMAT ] ]
    STDERR.close
  end

  s = WEBrick::HTTPServer.new( :BindAddress => $Config["listen"], :AccessLog=>access_log, :Logger => $Log, :Port => $Config["port"], :CGIPathEnv => ENV["GORG_CONF"])

  # Mount directories
  $Config["mounts"].each { |m|
    s.mount(m[0], WEBrick::HTTPServlet::FileHandler, m[1])
  }
  s.mount("/", GentooServlet, $Config["root"])

  # Start server
  trap("INT"){ s.shutdown }

  puts "\n\nStarting the Gorg web server on #{$Config['listen']}:#{$Config['port']}\n\nHit Ctrl-C or type \"kill #{$$}\" to stop it\n\n"

  s.start
end
