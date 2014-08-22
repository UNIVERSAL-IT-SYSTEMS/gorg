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

# Process CGI request, either from cgi or fcgi

require "gorg/base"

module Gorg
  def do_Filter(tmout=30, params=nil)
    # Read STDIN, transform, spit result out
    timeout(tmout) {
      # Give it a few seconds to read it all, then timeout
      xml = STDIN.read
      err, body, filelist = xproc(xml, params, false, true)
      if err["xmlErrLevel"] > 0 then
        STDERR.puts("#{err.collect{|e|e.join(':')}.join("\n")}")
      elsif (body||"").length < 1 then
        # Some transforms can yield empty content
        STDERR.puts("Empty body")
      else
        STDOUT.puts(body)
      end
    }
  rescue Timeout::Error, StandardError =>ex
    # Just spew it out
    STDERR.puts(ex)
  end
  
  def do_CGI(cgi)
    header = Hash.new
    if cgi.path_info.nil? || cgi.env_table["REQUEST_URI"].index("/#{File.basename($0)}/")
      # Sorry, I'm not supposed to be called directly, e.g. /cgi-bin/gorg.cgi/bullshit_from_smartass_skriptbaby
      raise Gorg::Status::Forbidden
    elsif cgi.request_method == "OPTIONS"
      cgi.out('Allow'=>'GET,HEAD'){""}
    elsif cgi.request_method == "HEAD" or cgi.request_method == "GET"
      # lighttp is b0rked despite what they say :(
      # PATH_INFO == "" and PATH_TRANSLATED == nil
      if cgi.path_info.length > 0 then
        # Apache, or any web browser that works
        path_info = cgi.path_info
      else
        # lighttp, use SCRIPT_NAME instead
        path_info = cgi.env_table['SCRIPT_NAME']
      end
      query = Hash.new
      cgi.params.each do |p, v|
        # fcgi 0.9 always provides an Array even with one
        # argument. Gorg only handles one argument, as far as I can
        # tell, so we take the first value in that case.
        value = if v.class == Array
                  v.first
                else
                  v
                end
        query[p] = value.to_s
      end
      # Get DOCUMENT_ROOT from environment
      $Config["root"] = cgi.env_table['DOCUMENT_ROOT']

      xml_file = cgi.path_translated||(cgi.env_table['DOCUMENT_ROOT']+cgi.env_table['SCRIPT_NAME'])
      if not FileTest.file?(xml_file)
        # Should have been checked by apache, check anyway
        raise Gorg::Status::NotFound
      else
        # Process request
        # Parse If-None-Match and If-Modified-Since request header fields if any
        inm=ims=nil
        begin
          inm = split_header_etags(cgi.env_table['HTTP_IF_NONE_MATCH']) if cgi.env_table['HTTP_IF_NONE_MATCH']
          ims = Time.parse(cgi.env_table['HTTP_IF_MODIFIED_SINCE']) if cgi.env_table['HTTP_IF_MODIFIED_SINCE']
          ims = nil if ims > Time.now # Dates later than current must be ignored
        rescue
          # Just ignore ill-formated data
          nil
        end
        if $Config['passthru'] && query["passthru"] && query["passthru"] != "0" then
          # passthru allowed by config and requested by visitor, return file as text/plain
          debug("Passthru granted for #{path_info}")
          mstat = File.stat(xml_file)
          raise Gorg::Status::NotModified.new(mstat) if notModified?(mstat, inm, ims)
          body = IO.read(xml_file)
          header['type'] = 'text/plain'
          # If client accepts gzip encoding and we support it, return gzipped file
          if $Config["zipLevel"] > 0 and ( cgi.accept_encoding =~ /gzip(\s*;\s*q=([0-9\.]+))?/ and ($2||"1") != "0" ) then
            body = gzip(body, $Config["zipLevel"])
            header['Content-Encoding'] = "gzip"
            header['Vary'] = "Accept-Encoding"
          end
        else
          # Get cookies and add them to the parameters
          if $Config["acceptCookies"] then
            # Add cookies to our params
            query.merge!(cookies_to_params(cgi.cookies))
          end

          if $Config["httphost"] then
            # Add HTTP_HOST to stylesheet params
            query["httphost"] = if $Config["httphost"][0] == '*' then
                                  cgi.host||""
                                elsif $Config["httphost"].include?('*') then
                                  $Config["httphost"][0]
                                elsif $Config["httphost"].include?(cgi.host) then
                                  $Config["httphost"][0]
                                else
                                  cgi.host||""
                                end
          end

          xml_query = query.dup # xml_query==params passed to the XSL, query=>metadata in cache
          if $Config["linkParam"] then
            xml_query[$Config["linkParam"]] = path_info
          end

          bodyZ = nil # Compressed version
          body, mstat, extrameta = Cache.hit(path_info, query, inm, ims)
          if body.nil? then
            # Cache miss, process file and cache result
            err, body, filelist, extrameta = xproc(xml_file, xml_query, true)
            if err["xmlErrLevel"] > 0 then
              raise "#{err.collect{|e|e.join(':')}.join('<br/>')}"
            elsif (body||"").length < 1 then
              # Some transforms can yield empty content (handbook?part=9&chap=99)
              # Consider this a 404
              raise Gorg::Status::NotFound
            else
              # Cache the output if all was OK
              mstat, bodyZ = Cache.store(body, path_info, query, filelist, extrameta)
              debug("Cached #{path_info}, mstat=#{mstat.inspect}")
              # Check inm & ims again as they might match if another web node had
              # previously delivered the same data
              if notModified?(mstat, inm, ims) and extrameta.join !~ /set-cookie/i
                raise Gorg::Status::NotModified.new(mstat)
              end
            end
          else
            if $Config["zipLevel"] > 0 then
              bodyZ = body
              body = nil
            end
          end
          # If client accepts gzip encoding and we support it, return gzipped file
          if bodyZ and $Config["zipLevel"] > 0 and ( cgi.accept_encoding =~ /gzip(\s*;\s*q=([0-9\.]+))?/ and ($2||"1") != "0" ) then
            body = bodyZ
            header['Content-Encoding'] = "gzip"
            header['Vary'] = "Accept-Encoding"
          else
            unless body then
              # We need to unzip bodyZ into body, i.e. we cached zipped data but client does not support gzip
              body = gunzip(bodyZ)
            end
          end
          # Add cookies to http header
          cookies = makeCookies(extrameta)
          if cookies then
            header['cookie'] = cookies
          end
          # Add Content-Type to header
          ct = contentType(extrameta)
          if ct then
            # Turn application/xhtml+xml into text/html if browser does not accept it
            if cgi.accept !~ /application\/xhtml\+xml/ and ct =~ /application\/xhtml\+xml(.*)$/ then
              header['type'] = "text/html#{$1}"
            else
              header['type'] = ct
            end
          else
            header['type'] = 'text/plain'
          end
        end
        # Add ETag & Last-Modified http headers
        # NB: it's simply mstat(file.xml) when passthru=1
        if mstat then
          header['ETag'] = makeETag(mstat)
          header['Last-Modified'] = mstat.mtime.httpdate
        end
      end
      cgi.out(header){body} 
    else # Not a HEAD or GET
      raise Gorg::Status::NotAllowed
    end
  rescue => ex
    if ex.respond_to?(:errCode) then
      # One of ours (Gorg::Status::HTTPStatus)
      cgi.out(ex.header){ex.html}
    else
      # Some ruby exceptions occurred, make it a 500
      syserr = Gorg::Status::SysError.new
      cgi.out('Status'=>syserr.errSts){syserr.html(ex)}
      error("do_CGI() failed: #{$!}")
    end
  end
end
