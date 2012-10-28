
# Rack Application class

require 'gorg/cgi'

module Gorg

  class Application
    # TODO: should be a class instance
    include Gorg

    def call(environment)
      request = Rack::Request.new(environment)
      response = Rack::Response.new

      hit = "#{$Config["root"]}#{request.path}"
      cacheName = request.path
      if FileTest.directory?(hit) and FileTest.exist?(hit+"/index.xml") then
        # Use $URI/index.xml for directories that have an index.xml file
        hit << "/index.xml"
        cacheName << "/index.xml"
      end
      hit.squeeze!('/')
      cacheName.squeeze!('/')
      if FileTest.directory?(hit) then
        return Rack::Directory.new($Config['root']).call(environment)
      else
        if hit !~ /\.(xml)|(rdf)|(rss)$/ then
          puts "Try to server a file for #{hit}"
          return Rack::File.new($Config['root']).call(environment)
        else
          if not FileTest.exist?(hit) then
            return Rack::File.new($Config['root']).call(environment)
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
              response['Charset'] = 'UTF-8'
              # Process xml file or return xml file if passthru=1
              if $Config['passthru'] && request.params && request.params["passthru"] && request.params["passthru"] != "0" then
                # passthru allowed by config and requested by visitor, return file as text/plain
                mstat = File.stat(hit)
                raise Gorg::Status::NotModified.new(mstat) if notModified?(mstat, inm, ims)
              debug("Passthru granted for #{hit}")
                body = IO.read(hit)
                # If client accepts gzip encoding and we support it, return gzipped file
                if $Config["zipLevel"] > 0 and (req.accept_encoding.include?("gzip") or req.accept_encoding.include?("x-gzip")) then
                  res.body = gzip(body, $Config["zipLevel"])
                  response['Content-Encoding'] = "gzip"
                  response['Vary'] = "Accept-Encoding"
                else
                  res.body = body
                end
                response['Content-Type'] = 'text/plain'
              else
                query_params = request.params.dup
                # Get cookies and add them to the parameters
                if $Config["acceptCookies"] then
                  # We need CGI:Cookie objects to be compatible with our cgi modules (stupid WEBrick)
                  puts "PENDING: raw header access for Cookie"
#                  ck = req.raw_header.find{|l| l =~ /^cookie: /i}
                  ck = false
                  if ck then
                    query_params.merge!(cookies_to_params(CGI::Cookie.parse($'.strip)))
                  debug "query params are " + query_params.inspect
                  end
                end
                if $Config["httphost"] then
                  # Add HTTP_HOST to stylesheet params
                  query_params["httphost"] = if $Config["httphost"][0] == '*' then
                                               request.host||""
                                             elsif $Config["httphost"].include?('*') then
                                               $Config["httphost"][0]
                                             elsif $Config["httphost"].include?(request.host) then
                                               $Config["httphost"][0]
                                             else
                                               request.host||""
                                             end
                end

                bodyZ = nil
                body, mstat, extrameta = Gorg::Cache.hit(cacheName, query_params, inm, ims)
                if body.nil? then
                  xml_query = query_params.dup
                  if $Config["linkParam"] then
                    xml_query[$Config["linkParam"]] = request.path
                  end
                  # Cache miss, process file and cache result
                  puts xml_query.inspect
                  err, body, filelist, extrameta = xproc(hit, xml_query, true)
                  puts err.inspect, extrameta.inspect
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
                if bodyZ and $Config["zipLevel"] > 0 and (request.accept_encoding.include?("gzip") or request.accept_encoding.include?("x-gzip")) then
                  res.body = bodyZ
                  response['Content-Encoding'] = "gzip"
                  response['Vary'] = "Accept-Encoding"
                else
                  if body then
                    response.write(body)
                  else
                    # We need to unzip bodyZ into body, i.e. we cached zipped data but client does not support gzip
                    response.write(gunzip(bodyZ))
                  end
                end
                # Add cookies to http header
                cookies = makeCookies(extrameta)
                if cookies then
                  cookies.each{|c| res.cookies << c.to_s}
                end
                # Add Content-Type to header based on actual content.
                ct = setContentType(body)
                if ct then
                  # Turn application/xhtml+xml into text/html if browser does not accept it
                  if request['HTTP_ACCEPT'].to_s !~ /application\/xhtml\+xml/ and ct =~ /application\/xhtml\+xml(.*)$/ then
                    response['Content-Type'] = "text/html#{$1}"
                  else
                    response['Content-Type'] = ct
                  end
                else
                  response['Content-Type'] = 'text/plain'
                end
              end
              if mstat then
                response['ETag'] = makeETag(mstat)
                response['Last-Modified'] = mstat.mtime.httpdate
              end
            rescue => ex
              if ex.respond_to?(:errCode) then
                # One of ours (Gorg::Status::HTTPStatus)
                res.body = ex.html
                res.status = ex.errCode
                ex.header.each {|k,v| response[k]=v unless k =~ /status|cookie/i}
              else
                raise
                # Some ruby exceptions occurred, make it a syserr
                syserr = Gorg::Status::SysError.new
                response.write(syserr.html(ex))
                response.status = syserr.errCode
              end
            end
          end
        end
      end

      response.finish
    end

  end

end
