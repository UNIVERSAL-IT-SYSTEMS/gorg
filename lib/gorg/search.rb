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


require 'dbi'
require 'yaml'
require 'gorg/base'
require 'cgi'

module GDig
  class GFile

    def initialize(root, f, xlang)
      @root = root
      @fname = f
      @xpath2lang = xlang
    end

    def txt
      unless @txt then
        @txt, @lang = txtifyFile
      end
      @txt
    end
    
    def lang
      unless @lang then
        @txt, @lang = txtifyFile
      end
      @lang
    end

    private    
    
    def txtifyFile
      x=Gorg::XSL.new
      x.xsl = <<EOXSL
<?xml version="1.0" encoding="UTF-8"?>
        <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
        <xsl:output encoding="UTF-8" method="text" indent="no"/>
        <xsl:template match="/">
EOXSL
      if (@xpath2lang||"").length > 1 then
        x.xsl << <<EOXSL
          <xsl:if test="#{@xpath2lang}">
            <xsl:value-of select="concat('%%LANG%%', #{@xpath2lang}, '%%&#x0A;')"/>
          </xsl:if>
EOXSL
      end
      x.xsl << <<EOXSL
        <xsl:apply-templates/>
        </xsl:template>
        <xsl:template match="*">
          <xsl:apply-templates select="@*"/>
          <xsl:apply-templates/>
        </xsl:template>
        <xsl:template match="@*">
          <xsl:value-of select="concat(' ',.,' ')"/>
        </xsl:template>
        </xsl:stylesheet>
EOXSL
      x.xroot = @root
      x.xml = @fname
      x.process
      
      if x.xerr and x.xerr["xmlErrLevel"] >= 3 then
        raise x.xerr["xmlErrMsg"]
      end

      t = x.xres
      if t =~ /^%%LANG%%([^%]+)%%/ then
        l = $1
        t = $'.strip
      else
        l = nil
      end
      t << @fname
      [t.squeeze("\n"), l]
    end
  end

  class DBFile
    attr_reader :fid, :webname
    def initialize(dbh, webname, localname)
      @dbh = dbh
      @webname = webname
      @localname = localname
      @row = @dbh.select_one("SELECT id,path,lang,timestamp,size FROM files where path = ?", webname)
      if @row then
        @fid = @row['id']
      else
        @fid = nil
      end
    end
    
    def DBFile.remove(dbh, fid)
      if fid then
        dbh.do("delete from files where id=#{fid}")
      end
    end
    
    def uptodate?
      if @fid then
        unless @row then
          @row = @dbh.select_one("SELECT id,path,lang,timestamp,size FROM files where id=#{@fid}")
        end
        if (fstat=File.stat(@localname)) and @row then
          @row['timestamp']==fstat.mtime.to_s and @row['size']==fstat.size
        else
          false
        end
      end
    end
    
    def update(blob, lang)
      fstat=File.stat(@localname)
      if @fid then
        # update
        sql = "update files set lang = ?, txt = ?, timestamp = ?, size = ? where id=#{@fid}"
        @dbh.do(sql, lang, blob, fstat.mtime.to_s, fstat.size)
      else
        # insert new one
        sql = "insert into files (path, lang, txt, timestamp, size) values (?, ?, ?, ?, ?)"
        @dbh.do(sql, webname, lang, blob, fstat.mtime.to_s, fstat.size)
        if id=@dbh.select_one("select last_insert_id()") then
          @fid = id[0]
        else
          @fid = nil
        end
      end
    end
  end
  
  class GSearch
    attr_reader :dbh, :searchTxt, :searchResult
    include Gorg
    
    def initialize
      @dbh = DBI.connect($Config['dbConnect'], $Config['dbUser'], $Config['dbPassword'])
      @dbh['AutoCommit'] = true
    end

    def indexDir
      wipe = false
      scanDir { |webName, localName|
        begin
          dbf = GDig::DBFile.new(@dbh, webName, localName)
          unless dbf.uptodate? then
            gf = GFile.new($Config['root'], webName, $Config['xlang'])
            blob = gf.txt
            lang = gf.lang
            if (lang||"").length < 1 then
              # No lang attribute, see if we can use the filename
              if $Config['flang'] and $Config['flang'].match(webName) then
                lang = $Config['flang'].match(webName)[1]
              end
            end
            dbf.update(blob, lang)
            wipe = true
            debug "#{Time.new.to_i}  #{webName} indexed"
          end
        rescue Exception => e
          error "Failed to index #{webName} : #{e.to_s}"
        end
      }
      wipeSearches if wipe
    end
    
    def cleanup
      # Remove files from db either because
      # they should now be excluded or because they do not exist anymore
      wipe = false
      @dbh.select_all('select id, path from files') { |row|
        if not fileMatch(row[1]) or not File.file?($Config['root']+row[1]) then
          DBFile.remove(@dbh, row[0])
          debug "GDig::GSearch:  #{row[1]} removed"
          wipe = true
        end
      }
      wipeSearches if wipe
    end

    def do_CGI(cgi)
      $Config["root"] = cgi.env_table['DOCUMENT_ROOT']||$Config["root"]
      query = {}
      # Get cookies
      if $Config["acceptCookies"] then
        # Add cookies to our params
        query = cookies_to_params(cgi.cookies)
      end
      # Add URI params that are not used by search engine (p,q,l,s)
      cgi.params.each{ |p, v| query[p] = v.to_s}
      
      # Choose language
      if cgi.has_key?("l") then
        lang = cgi["l"]
      elsif query.has_key?("SL") then
        lang = query["SL"]
      else
        lang = nil
      end

      # Perform search
      search(cgi["q"], lang)

      if cgi.has_key?("p") and cgi["p"] =~ /^[0-9]{1,5}$/ then
        p = cgi["p"].to_i
      else
        p = 1
      end

      if cgi.has_key?("s") and cgi["s"] =~ /^[0-9]{2,3}$/ then
        s = cgi["s"].to_i
      elsif query.has_key?("PL") and query["PL"] =~ /^[0-9]{2,3}$/ then
        s = query["PL"].to_i
      else
        s = 20
      end
      s = 120 if s > 120
      
      xml = xmlResult(p,s)
      header = {}; body = ""
      if cgi.has_key?("passthru") and $Config["passthru"] then
        header = {'type' => 'text/plain'}
        body = xml
      else
        if $Config["linkParam"] then
          query[$Config["linkParam"]] = cgi.script_name
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
                                cgi.host
                              end
        end

        err, body, filelist, extra = xproc(xml, query, false)
        if err["xmlErrLevel"] > 0 then
          raise "#{err.collect{|e|e.join(':')}.join('<br/>')}"
        end
        cookies = makeCookies(extra)
        ct = setContentType(body)
        # Turn application/xhtml+xml into text/html if browser does not accept it
        if cgi.accept !~ /application\/xhtml\+xml/ and ct =~ /application\/xhtml\+xml(.*)$/ then
          header = {'type' => "text/html#{$1}"}
        else
          header = {'type' => ct}
        end

        # Add cookies to http header
        if cookies then
          header['cookie'] = cookies
        end
      end
      # If client accepts gzip encoding and we support it, return gzipped file
      if $Config["zipLevel"] > 0 and ( cgi.accept_encoding =~ /gzip(\s*;\s*q=([0-9\.]+))?/ and ($2||"1") != "0" ) then
        body = gzip(body, $Config["zipLevel"])
        header['Content-Encoding'] = "gzip"
        header['Vary'] = "Accept-Encoding"
      end
      cgi.out(header){body}
    rescue => ex
      syserr = Gorg::Status::SysError.new
      cgi.out('Status'=>syserr.errSts){syserr.html(ex)}
      error("GSearch::do_CGI() failed: #{$!}")      
    end
    
    def search(str, lang)
      @searchTxt = str
      @searchResult = nil
      if (lang||"") == "" then
        @searchLang = '%'
      else
        @searchLang = lang
      end
      if str =~ /(^|\s)(([+<)(>~-][^+<)(>~-]+)|([^+<)(>~-]+\*))(\s|$)/ then
        @searchBool = "Y"
        boolClause = "in boolean mode"
      else
        @searchBool = "N"
        boolClause = ""
      end
      if @searchTxt.length > 0 then
        @searchResult = loadSearch
        unless @searchResult then
          @searchResult = []
          # Perform full text search
          sql = <<EOSQL
select id, path, lang, match (txt) against ( ? ) as score
from files
where lang like ? and match (txt) against ( ? #{boolClause} )
order by score desc
EOSQL
          @dbh.select_all(sql, @searchTxt, @searchLang, @searchTxt).each { |r| @searchResult << [r[0],r[1],r[2],r[3]] }
          saveSearch
        end
      end
      @searchResult
    end
    
    def xmlResult(page=1, pageLength=25)
      # <search page="p" pages="n">
      #   <for>search string</for>
      #   <found link="/path/to/file.xml" lang="fr">
      #     blah blah <b>word2</b> bleh
      #   </found>
      pageLength = 20 if pageLength < 1
      xml = "<?xml version='1.0' encoding='UTF-8'?>\n\n"
      
      if @searchResult and @searchResult.length >= 1 then
        removeDeadFiles
        nPages = @searchResult.length / pageLength #/
        nPages += 1 unless 0 == @searchResult.length.modulo(pageLength)
        page = nPages if page > nPages
        page = 1 if page < 1

        xml << "<search page='#{page}' pages='#{nPages}' pageLength='#{pageLength}' lang='#{xmlEscape(@searchLang)}' bool='#{@searchBool}'>\n"
        xml << xmlSearchFor
        @searchResult[(page-1)*pageLength..page*pageLength-1].each { |r|
          xml << "  <found link='#{r[1]}' lang='#{r[2]}' score='#{r[3]}'>\n"
          xml << xmlBlobSample(r[0]) << "\n"
          xml << "  </found>\n"
        }
      else
        xml << "<search page='0' pages='0'>\n"
        xml << xmlSearchFor
      end
      xml << "</search>\n"
    end
    
    def scanDir
      Dir.chdir($Config['root']) {
        `find -L . -type f`.split("\n").each{ |localFile|
          if File.file?(localFile) then
            webFile = localFile[1..-1]
            if fileMatch(webFile) then
              yield [webFile, File.expand_path(localFile)]
            end
          end
        }
      }
    end
    
    private
    
    def xmlBlobSample(fileID)
      blob = ""
      r = @dbh.select_one("select txt from files where id = #{fileID}")
      if r then
        blob = r[0]
        # Find first matching word and extract some text around it
        stxt = @searchTxt.tr('`.,\'"\-_+~<>/?;:[]{}+|\\)(*&^%\$\#@!', ' ').split(' ')
        regs = stxt.collect { |w| Regexp.new(w, true, 'U') }
        ix = nil
        regs.each { |r| break if ix=blob.index(r) }
        if ix then
          if ix < 80 then
            x = 0
          else
            x = blob[0,ix-60].rindex(/[ ,\.]/)
            x = 0 unless x
          end
          y = blob.index(/[,\. ]/, ix+80)
          y = -1 unless y
          blob = xmlEscape(blob[x..y])
          # Mark up sought words
          regs.each { |r| blob.gsub!(r){|t| "<b>#{t}</b>"} }
        else
          x = blob[120..-1].index(/[ ,\.]/)
          blob = xmlEscape(blob[0..x])
        end
      end
      blob
    end
    
    def xmlEscape(str)
      if str
        str.gsub('&','&amp;').gsub('>','&gt;').gsub('<','&lt;')
      else
        "w00t"
      end
    end
    
    def loadSearch
      if @searchTxt then
        r = @dbh.select_one("select result from savedsearches where words = ? and lang = ? and bool = ?", @searchTxt, @searchLang, @searchBool)
        if r then
          YAML::load(r[0])
        end
      end
    end
    
    def saveSearch
      if @searchTxt then
        @dbh.do("delete from savedsearches where words = ? and lang = ? and bool = ?", @searchTxt, @searchLang, @searchBool)
        @dbh.do("insert into savedsearches (words, lang, bool, result) values(?, ?, ?, ?)", @searchTxt, @searchLang, @searchBool, @searchResult.to_yaml)
      end
    end
    
    def wipeSearches
      @dbh.do("delete from savedsearches")
    end
    
    def fileMatch(f)
      $Config['in/out'].each { |inout|
        return inout[0] if inout[1].match(f)
      }
      false
    end
    
    def removeDeadFiles
      if @searchResult then
        @searchResult.reject!{ |r| not File.file?($Config['root']+r[1]) }
      end
    end
    
    def xmlSearchFor
      "  <for>#{xmlEscape(@searchTxt)}</for>\n" if @searchTxt
    end
    
  end
  
end
