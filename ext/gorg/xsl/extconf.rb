require "mkmf"

unless have_library("xml2", "xmlRegisterDefaultInputCallbacks")
 puts("libxml2 not found")
 exit(1)
end

unless have_library('xslt','xsltParseStylesheetFile')
 puts("libxslt not found")
 exit(1)
end

unless have_library('exslt','exsltRegisterAll')
 puts("libexslt not found")
 exit(1)
end

$LDFLAGS << ' ' << `xslt-config --libs`.chomp

$CFLAGS << ' ' << `xslt-config --cflags`.chomp

create_makefile("gorg/xsl")
