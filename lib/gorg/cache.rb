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


# Cache a bit of data based on 
#  . a path name as received by a webserver e.g.
#  . a list of parameters as received by a webserver e.g.
#  . a list of files it depends on

require "parsedate"
require "fileutils"
require "find"
require "digest"
require "digest/md5"

module Gorg

CacheStamp = "Gorg-#{Gorg::Version} Cached This Data. Do not alter this file. Thanks."

module Cache
  def Cache.init(config)
    @@lockfile = ".cache.cleaner.lock"
    @cacheDir = nil
    if FileTest.directory?(config["cacheDir"])
      if FileTest.writable?(config["cacheDir"])
        @cacheDir = config["cacheDir"].chomp("/")
      else
        warn "Cache directory not writable"
      end
    else
      warn "Invalid cache directory"
    end

    # Time-To-Live in seconds, cached items older than that will be considered too old
    @zipLevel = config["zipLevel"]
    @zip = @zipLevel > 0 ? ".gz" : ""
    @ttl = config["cacheTTL"]
    @cacheTree = config["cacheTree"]
    @maxFiles = config["maxFiles"]            # Max number of files in a single directory
    @maxSize = config["cacheSize"]*1024*1024  # Now in bytes
    @washNumber = config["cacheWash"]         # Clean cache dir after a store operation whenever rand(@washNumber) < 10
    @lastCleanup = Time.new-8e8               # Remember last time we started a cleanup so we don't pile them up
  end
  
  def Cache.hit(objPath, objParam={}, etags=nil, ifmodsince=nil)
    # objPath is typically a requested path passed from a web request but it
    # can be just any string. It is not checked against any actual files on the file system
    #
    # objParam is expected to be a hash or any object whose iterator yields two values
    #
    # 2 filenames are built with the arguments and should give 
    # the name of a metafile and a result file
    # if the result file is older than @ttl seconds, hit fails
    # The metafile is then checked for dependencies
    # It contains a list of filenames along with their size and mtime separated by ;;
    
    # etag and ifmodsince are used in a webserver context
    #   etag is defined if an ETag was part of an If-None-Match request field
    #   etag can be an array or a single string
    #   If the current ETag of the meta file matches, no data is returned (webserver should return a 304)
    #
    #   ifmodsince is a time object passed on an If-Modified-Since request field
    #   If the creation date of the meta file is earlier, no data is returned (webserver should return a 304)

    return nil if @cacheDir.nil? # Not initialized, ignore request
    
    # Reminder: filenames are full path, no need to prepend dirname
    dirname, basename, filename, metaname = makeNames(objPath, objParam)
    
    raise "Cache subdir does not exist" unless FileTest.directory?(dirname)

    # Hit the cache
    meta, mstat = IO.read(metaname), File.stat(metaname)  if metaname && FileTest.file?(metaname) && FileTest.readable?(metaname)
    raise "Empty/No meta file" if meta.nil? || meta.length < 1

    fstat = File.stat(filename) if filename && FileTest.file?(filename)
    raise "Empty/No data file" if fstat.nil?

    # Check the timestamps of files in the metadata
    meta = meta.split("\n")
    raise "I did not write that meta file" unless CacheStamp == meta.shift
    mline = meta.shift
    while mline and mline !~ /^;;extra meta$/ do
      f, s, d = mline.split(";;")
      if s.to_i < 0
        # File did not exist when cache entry was created
        raise "Required file #{f} has (re)appeared" if FileTest.file?(f) && FileTest.readable?(f)
      else
        # File did exist when cache entry was created, is it still there?
        raise "Required file #{f} has disappeared" unless FileTest.file?(f) && FileTest.readable?(f)
      
        fst = File.stat(f)
        raise "Size of #{f} has changed from #{fst.size} to #{s.to_i}" unless fst.size == s.to_i
        raise "Timestamp of #{f} has changed" unless Time.utc(*ParseDate.parsedate(d)) == fst.mtime.utc
      end
      mline = meta.shift
    end
    if mline =~ /^;;extra meta$/ then
      extrameta = meta.dup
    else
      extrameta = []
    end
    
    if notModified?(fstat, etags, ifmodsince) and extrameta.join !~ /set-cookie/i
      raise Gorg::Status::NotModified.new(fstat)
    end
    
    file = IO.read(filename) if filename && FileTest.file?(filename) && FileTest.readable?(filename)
    raise "Empty/No data file" if file.nil? || file.length < 1

    # Is the data file too old
    raise "Data file too old" unless @ttl==0 or (Time.new - fstat.mtime) < @ttl
    
    # Update atime of files, ignore failures as files might have just been removed
    begin
      t = Time.new
      File.utime(t, fstat.mtime, filename)
      File.utime(t, mstat.mtime, metaname)
    rescue
      nil
    end
    
    # If we get here, it means the data file can be used, return cache object (data, stat(datafile), extrameta)
    # The file is left (un)compressed, it's returned as it was stored
    [file, fstat, extrameta]
    
  rescue Gorg::Status::NotModified
    # Nothing changed, should return a 304
    debug("Client cache is up-to-date")
    raise
  rescue
    # cache hit fails if anything goes wrong, no exception raised
    debug("Cache hit on #{objPath} failed: (#{$!})")
    nil
  end


  def Cache.store(data, objPath, objParam={}, deps=[], extrameta=[])
    # Store data in cache so it can be retrieved based on the objPath and objParams
    # deps should contain a list of files that the object depends on
    # as returnd by our xsl processor, i.e. an array of [access_type, path] where
    # access_type can be "r", "w", or "o" for recpectively read, write, other.

    # Define content-type
    ct = setContentType(data)
    extrameta << "Content-Type:#{ct}"
    
    return nil if @cacheDir.nil? # Not initialized, ignore request
    
    # Cache only if no remote objects (ftp:// or http://) in list of used files
    if deps && deps.detect{|f| f[0] =~ /^o$/i }
      debug "#{objPath} not cached because it needs remote resources"
      return nil
    end

    dirname, basename, filename, metaname = makeNames(objPath, objParam)

    FileUtils.mkdir_p(dirname) unless FileTest.directory?(dirname)
    
    # Write Meta file to a temp file (with .timestamp.randomNumber appended)
    metaname_t = "#{metaname}.#{Time.new.strftime('%Y%m%d%H%M%S')}.#{rand(9999)}"

    # Data might need to be just a link to another .Data file
    # if we find another requested path with different params but
    # with identical MD5 sums
    # Which is why we keep a ...xml.Data.[md5 sum] file without the parameters
    # in its name that we can hard link to.
    # e.g. A moron hits for 10 full handbooks with toto=1..10 in the URI,
    # we'd end up with 10 identical large copies. With links we have only one

    # Old versions are expected to be cleaned up by the cacheWash() routine
    # A Dir.glob() to find the previous ones would be too expensive
    
    # Compute MD5 digest
    md5 = Digest::MD5.hexdigest(data)
    
    # Compress data if required
    if @zipLevel > 0 then
      bodyZ = data = gzip(data, @zipLevel)
    else
      bodyZ = nil
    end
    
    # Set mtime of data file to latest mtime of all required files
    # so that caching can work better because mtimes will be
    # identical on all webnodes whereas creation date of data
    # would be different on all nodes.
    maxmtime = Time.now-8e8
    fstat = nil
    
    begin
      timeout(10){
        File.open("#{metaname_t}", "w") {|fmeta|
          fmeta.puts(CacheStamp)
          # Write filename;;size;;mtime for each file in deps[]
          deps.each {|ffe|
            ftype = ffe[0]
            fdep = ffe[1]
            if FileTest.file?(fdep)
              s = File.stat(fdep)
              fmeta.puts("#{fdep};;#{s.size};;#{s.mtime.utc};;#{ftype}")
              maxmtime = s.mtime if s.mtime > maxmtime and ftype =~ /^r$/i
            else
              # A required file does not exist, use size=-1 and old timestamp
              # so that when the file comes back, the cache notices a difference
              # and no cache miss gets triggered as long as file does not exist
              fmeta.puts("#{fdep};;-1;;Thu Nov 11 11:11:11 UTC 1971")
            end
          }
          fmeta.puts ";;extra meta"
          extrameta.each { |m| fmeta.puts m }
        }
        # Get exclusive access to the cache directory while moving files and/or creating data files
        File.open(dirname) { |lockd|
          while not lockd.flock(File::LOCK_NB|File::LOCK_EX)
            # Timeout does not occur on a blocking lock
            # Try a non-bloking one repeatedly for a few seconds until timeout occurs or lock is granted
            # We are in a timeout block, remember
            sleep 0.1
          end
          # Remove previous Data
          FileUtils.rm_rf(filename)

          # mv temp meta file to meta file
          FileUtils.mv(metaname_t, metaname)

          # We keep a data file for the same requested path, with different params,
          # but which ends up with same MD5 sum, i.e. identical results because of unused params
          linkname = "#{basename}.#{md5}#{@zip}"
          if FileTest.file?(linkname) then
            # Data file already there, link to it
            File.link(linkname, filename)
          else
            # Write data file and set its mtime to latest of all files it depends on
            File.open("#{filename}", "w") {|fdata| fdata.write(data)}
            # Create link
            File.link(filename, linkname)
          end
          # mtime might need to be updated, or needs to be set
          # e.g. when a dependency had changed but result files is identical
          # This is needed to keep Last-Modified dates consistent across web nodes
          File.utime(Time.now, maxmtime, filename)
          fstat = File.stat(filename)
        }
      }
    ensure
      FileUtils.rm_rf(metaname_t)
    end
    
    # Do we clean the cache?
    washCache(dirname, 10) if @washNumber > 0 and rand(@washNumber) < 10
    
    # Return stat(datafile) even if it's just been removed by washCache
    # because another web node might still have it or will have it.
    # Anyway, the cached item would be regenerated on a later request
    # and a 304 would be returned if still appropriate at the time.

    # Return fstat of data file (for etag...) and zipped file
    [fstat, bodyZ]
    
  rescue Timeout::Error, StandardError =>ex
    if ex.class.to_s =~ /timeout::error/i then
      warn("Timeout in cache store operation")
    else
      warn("Cache store error (#{$!})")
    end
    # Clean up before leaving
    FileUtils.rm_rf(filename||"")
    FileUtils.rm_rf(metaname||"")
    nil # return nil so that caller can act if a failed store really is a problem
  end
    
    
  def Cache.washCache(dirname, tmout=30, cleanTree=false)
    # Clean cache entries that are either too old compared to TTL (in seconds)
    # or reduce total size to maxSize (in MB)
    # oldDataOnly means to look only for unused *.Data.[md5] files that are not used anymore 
    # because file has been modified and has generated a new *.Data.[md5] file
    
    # timeout is the maximum time (in seconds) spent in here

    return nil if @cacheDir.nil? # Not initialized, ignore request
    
    # Also ignore request if dirname not equal to @cacheDir or under it
    return nil unless dirname[0, @cacheDir.length] == @cacheDir
    
    # Also ignore request if dirname does not exist yet
    return nil unless FileTest.directory?(dirname)
    
    # Also return if less than a minute has elapsed since latest cleanup
    t0 = Time.new
    return nil if t0 - @lastCleanup < 60
    
    # Remember for next time
    @lastCleanup = t0

    Dir.chdir(dirname) { |d|
      # Recreate lock file if it's been lost
      unless File.exist?(@@lockfile)
        File.open(@@lockfile, "w") { |lockf| lockf.puts("Lock file created on #{Time.now.utc} by gorg")}
      end
        
      # Grab lockfile
      File.open(@@lockfile) { |lockf| 
        if lockf.flock(File::LOCK_NB|File::LOCK_EX) then
          infoMsg = "Cleaning up cache in #{dirname} (cleanTree=#{cleanTree}, tmout=#{tmout})"
          info(infoMsg)
          puts infoMsg if cleanTree

          timeout(tmout) {
            totalSize, deletedFiles, scannedDirectories = washDir(dirname, cleanTree)
            if totalSize >= 0 then
              # Size == -1 means dir was locked, throwing an exception would have been nice :)
              infoMsg = if cleanTree then
                          "Cache in #{dirname} is now #{totalSize/1024/1024} MB, #{deletedFiles} files removed in #{(Time.now-t0).to_i} seconds in #{scannedDirectories} directories"
                        else
                          "#{deletedFiles} files removed in #{(Time.now-t0).to_i} seconds in #{dirname}"
                        end
              info(infoMsg)
              puts infoMsg if cleanTree
            end
          }
        else
          # Locked dir, another process is busy cleaning up/
          debug("#{dirname} locked, skipping")
          puts("#{dirname} locked, skipping") if cleanTree
        end # of lock test
      } # end of File.open(@@lockfile),  close & release lock automatically
    }
  rescue Timeout::Error
    info("Timeout while cleaning #{dirname}")
    puts("Timeout while cleaning #{dirname}") if cleanTree
  rescue StandardError =>ex
    error("Error while cleaning cache: #{ex}")
    puts("Error while cleaning cache: #{ex}") if cleanTree
  end

  
  private

  def Cache.washDir(dirname, cleanTree)
    # Clean up cache starting from dirname and in subdirectories if cleanTree is true
    # Return [newSize in bytes, # deleted files, # scanned directories]
    size = nDeleted = nDirectories = 0

    Dir.chdir(dirname) { |d|
      hIno = Hash.new(0) # hash of file inodes with more than one link
      lst = Array.new    # array of file names, atime, ...
      ttl = @ttl
      ttl = 8e8 if ttl == 0 # No ttl, keep very old docs!

      # Get list of files sorted on their dirname+atime
      Find.find('.') { |f|
        begin
          unless f =~ /^\.$|#{@@lockfile}/  # ignore "." and lockfile 
            ff = File.stat(f)
            if ff.directory? then
              Find.prune unless cleanTree
            elsif ff.file? and f =~ /Meta|Data/ then
              hIno[ff.ino] = ff.nlink if ff.nlink > 1
              # List of files has [name, atime, size, # links, inode]
              lst << [f, ff.atime, ff.size, ff.nlink, ff.ino]
            end
          end
        rescue
          nil # File.stat can fail because file could have been deleted, ignore error
        end
      }
      
      # Compute total size
      size = lst.inject(0){ |tot, a| tot + if a[3] > 0 then a[2]/a[3] else 0 end }
      
      # Delete old *.Data.[md5] files that are not being referenced anymore/
      lst.each { |a|
        if a[3] == 1 && a[0] =~ /\.Data\.[0-9a-f]+(.gz)?$/ then
          # Data file with no more links pointing to it
          FileUtils.rm_rf(a[0])
          nDeleted += 1
          size -= a[2]
          a[3] = 0 # Mark as deleted
        end
      }
      
      # Sort all files on atime
      lst.sort!{ |a1, a2| a1[1] <=> a2[1] }
      
      t0 = Time.new
      # Clean until size < maxSize _AND_ atime more recent than TTL
      lst.each { |a|
        break if size < @maxSize and t0-a[1] < ttl
        next if a[3] < 1 # Already deleted in previous step
        FileUtils.rm_rf(a[0])
        nDeleted += 1
        # Total size -= file size IF last link to data
        if a[3] == 1 || hIno[a[4]] <= 1 then
          size -= a[2]
        end
        hIno[a[4]] -= 1 if hIno[a[4]] > 0
        a[3] = 0 # Mark as deleted by setting nlinks to 0
      }
      
      # Remove deleted files from array
      lst.reject! { |a| a[3] < 1 }
      
      
      # Sort files per directory to enforce maxFiles
      if cleanTree then
        # Split the array in an array per directory
        # and keep the files sorted on atime in each directory
        slst = Hash.new
        lst.length.times {
          a = lst.shift
          d = File.dirname(a[0])
          if slst[d] then
            slst[d] << a
          else
            slst[d] = [a]
          end
        }
      else
        # If not cleaning whole tree, we have only a single dir
        slst = {"." => lst}
      end
      
      nDirectories = slst.length

      slst.each { |d, lst|
        # Remove oldest files so that we have less than @maxFiles in it
        if lst.length >= @maxFiles then
          # Remove to leave up 90% of #maxFiles so we don't clean up only a handful of files repeatedly
          (lst.length - 9*@maxFiles/10).times {
            if a = lst.shift then
              FileUtils.rm_rf(a[0])
              nDeleted += 1
              # Total size -= file size IF last link to data
              if a[3] == 1 || hIno[a[4]] <= 1 then
                size -= a[2]
              end
              hIno[a[4]] -= 1 if hIno[a[4]] > 0
            end
          }
        end
      }
    } #end of chdir
    [size, nDeleted, nDirectories]
  end
                    
  
  def Cache.makeNames(obj, params)
    # Build meta filename and data filename from arguments
    #
    # obj is broken into a path and a filename with appended params
    # e.g. /proj/en/index.xml?style=printable becomes /proj/en and index.xml+printable+yes
    #  or  .#proj#en#index.xml+printable+yes
    # depending on cacheTree param value

    # .Meta and .Data are appended respectively to the meta filename and data filename
    # Base is the filename without appending params, e.g. .#proj#en#index.xml.Data
    if @cacheTree then
      # Use a path and a file
      dir = "#{@cacheDir}#{File.dirname(obj)}"
      base = f = File.basename(obj)
    else
      # Convert full path into a single filename
      dir = @cacheDir
      base = f = ".#{obj.gsub(/\//,'#')}"
    end

    f = "#{f}+#{params.reject{|k,v| k.nil?}.sort.join('+')}" if params && params.to_a.length > 0    
    # Remove funky chars and squeeze duplicates into single chars
    f = f.gsub(/[^\w\#.+_-]/, "~").squeeze("~.#+")
    
    # Return names for Data and Meta files, and just the filepath (e.g. #proj#en#index.xml)
    [dir, "#{dir}/#{base}.Data", "#{dir}/#{f}.Data#{@zip}", "#{dir}/#{f}.Meta"]
  end
end

end
