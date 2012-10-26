/*
    Copyright 2004,   Xavier Neys   (neysx@gentoo.org)

    This file is part of gorg.

    gorg is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    gorg is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with gorg; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*/

#include "xsl.h"

/*
 * Copied from xmlIO.c from libxml2
 */
static int xmlFileWrite (void * context, const char * buffer, int len)
{
  int items;
  
  if ((context == NULL) || (buffer == NULL))
      return(-1);
  items = fwrite(&buffer[0], len, 1, (FILE *) context);
  if ((items == 0) && (ferror((FILE *) context))) {
      //xmlIOErr(0, "fwrite()");
      __xmlIOErr(XML_FROM_IO, 0, "fwrite() failed");
      return(-1);
  }
  return(items * len);
}

extern int xmlLoadExtDtdDefaultValue;
static int xmlOptions = XSLT_PARSE_OPTIONS | XML_PARSE_NOWARNING;

/*Enum xmlParserOption {
    XML_PARSE_RECOVER = 1 : recover on errors
    XML_PARSE_NOENT = 2 : substitute entities
    XML_PARSE_DTDLOAD = 4 : load the external subset
    XML_PARSE_DTDATTR = 8 : default DTD attributes
    XML_PARSE_DTDVALID = 16 : validate with the DTD
    XML_PARSE_NOERROR = 32 : suppress error reports
    XML_PARSE_NOWARNING = 64 : suppress warning reports
    XML_PARSE_PEDANTIC = 128 : pedantic error reporting
    XML_PARSE_NOBLANKS = 256 : remove blank nodes
    XML_PARSE_SAX1 = 512 : use the SAX1 interface internally
    XML_PARSE_XINCLUDE = 1024 : Implement XInclude substitition
    XML_PARSE_NONET = 2048 : Forbid network access
    XML_PARSE_NODICT = 4096 : Do not reuse the context dictionnary
    XML_PARSE_NSCLEAN = 8192 : remove redundant namespaces declarations
    XML_PARSE_NOCDATA = 16384 : merge CDATA as text nodes
    XML_PARSE_NOXINCNODE = 32768 : do not generate XINCLUDE START/END nodes
}*/

/*
 *   Library global values that need to be accessed by the callbacks
 *   Make sure the lib init routine registers them with ruby's GC
 */
VALUE g_xroot=Qnil;
VALUE g_xfiles=Qnil;
VALUE g_xmsg=Qnil;
VALUE g_mutex=Qnil;
VALUE g_xtrack=Qnil; // true/false, no need to register this one

/*
 * Store ID's of ruby methodes to speed up calls to rb_funcall*
 * so that we do not have to call rb_intern("methodName") repeatedly.
 */
struct {
  int include;
  int to_a;
  int to_s;
  int length;
  int synchronize;
} id;


/*
 *  Add file to list of requested files, if not already in our array
 */
void addTrackedFile(char *f, const char *rw)
{
  VALUE rbNewPath;
  VALUE rwo;
  VALUE rbNewEntry;

  if (Qtrue == g_xtrack)
  {
    switch(*rw)
    {
      case 'R':
      case 'r':
        rwo = rb_str_new2("r");
        break;
      case 'W':
      case 'w':
        rwo = rb_str_new2("w");
        break;
      default:
        rwo = rb_str_new2("o");
    }
    rbNewPath = rb_str_new2(f);
    rbNewEntry = rb_ary_new();
    rb_ary_push(rbNewEntry, rwo);
    rb_ary_push(rbNewEntry, rbNewPath);
    if (Qtrue != rb_funcall(g_xfiles, id.include, 1, rbNewEntry))
      rb_ary_push(g_xfiles, rbNewEntry);
  }
}

/*
 *  libxml2 File I/O Match Callback :
 *    return 1 if we must handle the file ourselves
 */
int XRootMatch(const char * URI) {
  int r = 0;
//printf("NSX-RootMatch: %s\n",URI);
  if ( URI != NULL && (*URI == '/' || !strncmp(URI, "file:///", 8)))
    r = 1;
  else
    if (!strncmp(URI, "ftp://", 6) || !strncmp(URI, "http://", 7))
      // Add URI to list of requested files to let caller know remote files are used
      addTrackedFile((char *)URI, "o");

  return r;
}


/*
 *  libxml2 File I/O Open Callback :
 *    open the file, prepend $xroot if necessary and add file to list of requested files on input
 */
void *XRootOpen (const char *filename, const char* rw) {
  char *path = NULL;
  char *fakexml = NULL;
  FILE *fd;
  char *rbxrootPtr="";
  int  rbxrootLen=0;
  char empty[] = "<?xml version='1.0'?><missing file='%s'/>";
  int  pip[2];
  struct stat notused;

//printf("NSX-RootOpen: %s\n", filename);

  if (filename == NULL || (*filename != '/' && strncmp(filename, "file:///", 8))){
	  return NULL; // I told you before, I can't help you with that file ;-)
  }
  
  if (g_xroot != Qnil)
  {
    rbxrootPtr = RSTRING(g_xroot)->ptr;
    rbxrootLen = RSTRING(g_xroot)->len;
  }
  path = (char *) malloc((strlen(filename) + rbxrootLen + 1) * sizeof(char));
  if (path == NULL)
    return NULL;
    
  if (!strncmp(filename, "file:///", 8))
  {
    // Absolute path, do not prepend xroot, e.g. file:///etc/xml/catalog
    strcpy ( path, filename+7);
  }
  else
  {
    // If requested file is already under xroot, do not prepend path with xroot
    // Example:
    //   Say we have xroot="/htdocs"
    //   when calling document('../xml/file.xml') in /htdocs/xsl/mysheet.xsl,
    //   the lib will already have replaced the .. with /htdocs
    //   and there is no need to add /htdocs
    //   On the other hand, if we call document('/xml/file.xml') in /htdocs/xsl/mysheet.xsl,
    //   because we know our root is /htdocs, then we need to prepend xroot to get /htdocs/xml/file.xml
    //   The consequence of that is that /${DocRoot}/${DocRoot}/whatever is not usable. Get over it.
    //
    //   Besides, it is also possible that a file is located outside the $DocumentRoot, e.g. ~usename/file.xml
    //   that apache would have expanded to /home/username/public_html/file.xml e.g.
    if (rbxrootLen && strncmp(rbxrootPtr, filename, rbxrootLen) && stat(filename,&notused))
    {
      // Requested file is not already under $DocRoot, prepend it
      strcpy (path, rbxrootPtr);
      strcat (path, filename);
    }
    else
    {
      // Use the filename that was requested as-is
      strcpy(path, filename);
    }
  }

  // Add file to list of requested files
  addTrackedFile(path, rw);
  
  fd = fopen(path, rw);
  free(path);

  if (*rw == 'r' && fd == NULL && strncmp(filename, "file:///", 8) && strlen(filename)>4 && strncmp((strlen(filename)-4)+filename, ".dtd", 4) && strncmp((strlen(filename)-4)+filename, ".xsl", 4))
    // Return fake xml
    // We don't know for sure that libxml2 wants an xml file from a document(),
    // but what the heck, let's just pretend
    if (pipe(pip))
      return (void *) NULL;
    else
    {
      fakexml = (char *) malloc((strlen(filename) + sizeof(empty)) * sizeof(char));
      if (path == NULL)
        return NULL;
      sprintf(fakexml, empty, filename);
      write(pip[1], fakexml, strlen(fakexml));
      close(pip[1]);
      free(fakexml);
      return (void *) fdopen(pip[0], "r");
    }
  else
    return (void *) fd;
}

int XRootClose (void * context) {
  if (context == (void *) -1)
    return 0;
  else
    return xmlFileClose(context);
}

void *XRootInputOpen (const char *filename) {
  return XRootOpen (filename, "r");
}

void *XRootOutputOpen (const char *filename) {
  return XRootOpen (filename, "w");
}


/*
 *   Intercept xsl:message output strings, 
 *     If one starts with "%%GORG%%" then it to our @xmsg array.
 *     If not, pass it to the default generic handler of libxslt
 */
void xslMessageHandler(void *ctx ATTRIBUTE_UNUSED, const char *msg, ...)
{
    va_list args;
    char *str;
    int len;

    va_start(args, msg);
    len = vasprintf(&str, msg, args);
    va_end(args);

    if (len > 0)
    {
      if (!strncmp(str, "%%GORG%%", 8))
      {
        if (len > 8)
        {
          rb_ary_push(g_xmsg, rb_str_new2(str+8));
        }
      }
      else
      {
        // Not for gorg, spit it out on stderr as libxslt would do
        fputs(str, stderr);
      }
      // Need to free pointer that was allocated by vasprintf
      free(str);
    }
}


/*
 *   Try to distinguish between a filename and some xml
 *   without accessing the filesystem or parsing the string as xml
 *
 *   If the string is long (>FILENAME_MAX)  or
 *   starts with "<?xml" or "<?xsl"  or
 *   contains newline chars,
 *   we assume it is some kind of xml, otherwise we assume it is a filename
 */
int looksLikeXML(VALUE v)
{
  return    (RSTRING(v)->len > FILENAME_MAX)
         || (!strncmp(RSTRING(v)->ptr, "<?xml", 5))
         || (!strncmp(RSTRING(v)->ptr, "<?xsl", 5))
         || (strstr(RSTRING(v)->ptr, "\n"));
//            We could also try with " " but some are stupid enough to use spaces in filenames
}
 
// I got stumped and needed this ;-)
void dumpCleanup(char * str, struct S_cleanup c)
{
printf( "%s\n"
        "\nparams=%08x"
        "\ndocxml=%08x"
        "\ndocxsl=%08x"
        "\ndocres=%08x"
        "\n   xsl=%08x"
        "\ndocstr=%08x"
        "\n=======================\n", str, c.params, c.docxml, c.docxsl, c.docres, c.xsl, c.docstr);
}

/*
 *  my_raise : cleanup and raise ruby exception
 *
 *  cleanup frees xsl docs and allocated memory, pointers are in passed struct
 *  then raises the passed exception
 *
 *  struct of pointers can be NULL (no memory to free) and
 *  exception can be NULL (clean up only, do not call rb_raise)
 *
 * Set last error level and last error message if applicable and available
 */
void my_raise(VALUE obj, s_cleanup *clean, VALUE rbExcep, char *err)
{
  xmlErrorPtr xmlErr = NULL;
  VALUE hErr;
  
  if (!NIL_P(obj))
  {
    xmlErr = xmlGetLastError();
    hErr = rb_hash_new();
    if (xmlErr)
    {
      // It seems we usually get a \n at the end of the msg, get rid of it
      if (*(xmlErr->message+strlen(xmlErr->message)-1) == '\n')
        *(xmlErr->message+strlen(xmlErr->message)-1) = '\0';
      // Build hash with error level, code and message
      rb_hash_aset(hErr, rb_str_new2("xmlErrCode"), INT2FIX(xmlErr->code));
      rb_hash_aset(hErr, rb_str_new2("xmlErrLevel"), INT2FIX(xmlErr->level));
      rb_hash_aset(hErr, rb_str_new2("xmlErrMsg"), rb_str_new2(xmlErr->message));
    }
    else
    {
      // Build hash with only an error code of 0
      rb_hash_aset(hErr, rb_str_new2("xmlErrCode"),  INT2FIX(0));
      rb_hash_aset(hErr, rb_str_new2("xmlErrLevel"), INT2FIX(0));
    }
    rb_iv_set(obj, "@xerr", hErr);
  }
  
  if (clean)
  {
    //dumpCleanup("Freeing pointers", *clean);
    free(clean->params);
    xmlFree(clean->docstr);
    xmlFreeDoc(clean->docres);
    xmlFreeDoc(clean->docxml);
    //xmlFreeDoc(clean->docxsl);  segfault /\/ Veillard said xsltFreeStylesheet(xsl) does it
    xsltFreeStylesheet(clean->xsl);
  }
  // Clean up xml stuff
  xmlCleanupInputCallbacks();
  xmlCleanupOutputCallbacks();
  xmlResetError(xmlErr);
  xmlResetLastError();  
  xsltCleanupGlobals();
  xmlCleanupParser();
  xsltSetGenericErrorFunc(NULL, NULL);

  // Reset global variables to let ruby's GC do its work
  g_xroot = Qnil;
  g_xfiles = Qnil;
  g_xmsg = Qnil;

  // Raise exception if requested to
  if (rbExcep != Qnil)
  {
    rb_raise(rbExcep, err);
  }
}


/*
 *  Register input callback with libxml2
 *
 *  We need to repeat this call because libxml cleanup unregisters and we like cleaning up
 */
void my_register_xml(void)
{
  // Enable exslt
  exsltRegisterAll();

  // Register default callbacks, e.g.http://
  xmlRegisterDefaultInputCallbacks();
  xmlRegisterDefaultOutputCallbacks();

/* NO NEED xmlRegisterInputCallbacks(xmlIOHTTPMatch, xmlIOHTTPOpen, xmlIOHTTPRead, xmlIOHTTPClose);
xmlRegisterInputCallbacks(xmlFileMatch, xmlFileOpen, xmlFileRead, xmlFileClose);*/

  // Add our own file input callback
  if (xmlRegisterInputCallbacks(XRootMatch, XRootInputOpen, xmlFileRead, XRootClose) < 0)
  {
    rb_raise(rb_eSystemCallError, "Failed to register input callbacks");
  }

  // Add our own file output callback to support exslt:document
  if (xmlRegisterOutputCallbacks(XRootMatch, XRootOutputOpen, xmlFileWrite, xmlFileClose) < 0)
  {
    rb_raise(rb_eSystemCallError, "Failed to register output callbacks");
  }
  // Add our own xsl:message handler
  xsltSetGenericErrorFunc(NULL, xslMessageHandler);
  
  xsltDebugSetDefaultTrace(XSLT_TRACE_NONE);
  xmlSubstituteEntitiesDefault(1);
  xmlLoadExtDtdDefaultValue=1;
}


/*
 *  Check that parameters are usable, i.e. like
 *  [p1, v1]                : single parameter
 *  [[p1, v1], [p2, v2]...] : several pairs of (param name, value)
 *  {p1=>v1...}             : a hash of (param name, value)
 *  nil                     : no parameter
 *
 *  Raise an exceptiom if not happy or return the list of params as
 *  [[p1, v1], [p2, v2]...]
 */
VALUE check_params(VALUE xparams)
{
  VALUE retparams=Qnil;

  if (!NIL_P(xparams))
  {
    VALUE ary;
    VALUE param;
    int len, plen;
    int i;
    
    // Reject some single values straight away
    switch (TYPE(xparams))
    {
      case T_FLOAT:
      case T_REGEXP:
      case T_FIXNUM:
      case T_BIGNUM:
      case T_STRUCT:
      case T_FILE:
      case T_TRUE:
      case T_FALSE:
      case T_DATA:
      case T_SYMBOL:
        rb_raise(rb_eTypeError, "Invalid parameters");
        return Qnil;
    }
    // if xparams is not an array, try to make one
    ary = rb_funcall(xparams, id.to_a, 0);

    // Now check that our array is a suitable array:
    // empty array => Qnil
    // array.length==2, could be 2 params [[p1,v1],[p2,v2]] or 1 param [p,v]
    // if both items are arrays, we have a list of params, otherwise we have a single param
    len = RARRAY(ary)->len;
    switch (len)
    {
      case 0:
        retparams = Qnil;
        break;
      case 2:
        // fall through to default if we have 2 arrays, otherwise, we must have 2 strings
        if (! (TYPE(rb_ary_entry(ary,0))==T_ARRAY && TYPE(rb_ary_entry(ary,1))==T_ARRAY))
        {
          VALUE s1 = rb_funcall(rb_ary_entry(ary,0), id.to_s, 0);
          VALUE s2 = rb_funcall(rb_ary_entry(ary,1), id.to_s, 0);

          // Both items must be strings
          retparams = rb_ary_new3(2L, s1, s2);
          break;
        }
      default:
        // scan array and check that each item is an array of 2 strings
        retparams = rb_ary_new();
        for (i=0; i < len; ++i)
        {
          if ( TYPE(rb_ary_entry(ary,i)) != T_ARRAY )
          {
            rb_raise(rb_eTypeError, "Invalid parameters");
            return Qnil;
          }
          param = rb_ary_entry(ary,i);
          plen = NUM2INT(rb_funcall(param, id.length, 0));
          if ( plen != 2 )
          {
            rb_raise(rb_eTypeError, "Invalid parameters");
            return Qnil;
          }
          VALUE s1 = rb_funcall(rb_ary_entry(param,0), id.to_s, 0);
          VALUE s2 = rb_funcall(rb_ary_entry(param,1), id.to_s, 0);

          rb_ary_push(retparams, rb_ary_new3(2L, s1, s2));
        }
    }
  }
  return retparams;
}


/*
 *  Build array of pointers to strings
 *
 *  return NULL or pointer
 */
char *build_params(VALUE rbparams)
{
  char *ret;
  char **paramPtr;
  char *paramData;
  int i;
  VALUE tempval;
  VALUE tempstr;
  char quotingChar;

  if (rbparams == Qnil)
    // You shoud not call this if you have no params, see it as an error
    return NULL;

  // Compute total block size in one go
  tempval = rb_funcall(rbparams, id.to_s, 0);
  ret = malloc (  ((RARRAY(rbparams)->len)*2+1) * sizeof(void *) // Two pointers per [param, value] + 1 NULL
                + (RARRAY(rbparams)->len) * 4 * sizeof(char)     // Quotes around values + 1 NULL per value
                + (RSTRING(tempval)->len) * sizeof(char)         // Size of param names & values
                  );
  if ( ret==NULL)
    return NULL; // out of memory

  paramPtr = (char **)ret;
  paramData = ret + ((RARRAY(rbparams)->len)*2+1) * sizeof(void *);
  // Copy each param name & value
  for (i=0; i<RARRAY(rbparams)->len; ++i)
  {
    tempval = rb_ary_entry(rbparams, i); // ith param, i.e. [name, value]
    
    // 1. Add param name
    
    tempstr = rb_ary_entry(tempval, 0);  // param name
    // Add param name address to list of pointers
    *paramPtr++ = paramData;
    // Copy param name into data block
    strcpy(paramData, RSTRING(tempstr)->ptr);
    // Move data pointer after inserted string
    paramData += 1+ RSTRING(tempstr)->len;
    
    // 2. Copy param value, quoting it with ' or "
    
    tempstr = rb_ary_entry(tempval, 1);  // param value
    // Don't bother if param is a mix of ' and ", users should know better :-)
    // or it's been checked already. Here we expect params to be OK.
    quotingChar = '"';
    if ( strchr(RSTRING(tempstr)->ptr, quotingChar) )
      quotingChar = '\''; // Use ' instead of "

    // Add para value address in list of pointers
    *paramPtr++ = paramData;

    // Start with quoting character
    *paramData++ = quotingChar;
    // Copy value
    strcpy(paramData, RSTRING(tempstr)->ptr);
    // Move data pointer after inserted string
    paramData += RSTRING(tempstr)->len;
    // Close quote
    *paramData++ = quotingChar;
    // End string with \0
    *paramData++ = '\0';
  }
  // Terminate list of pointers with a NULL
  *paramPtr = NULL;

  return ret;
}




/*
 *   Parse stylesheet and xml document, apply stylesheet and return result
 */
VALUE xsl_process_real(VALUE none, VALUE self)
{
  s_cleanup myPointers;
  int docstrlen;
  
  VALUE rbxml, rbxsl, rbout, rbparams, rbxroot;

  // Get instance data in a reliable format
  rbxml = rb_iv_get(self, "@xml");
  if (NIL_P(rbxml))
    rb_raise(rb_eArgError, "No XML data");
  rbxml = StringValue(rbxml);
  if (!RSTRING(rbxml)->len)
    rb_raise(rb_eArgError, "No XML data");
  rbxsl = rb_iv_get(self, "@xsl");
  if (NIL_P(rbxsl))
    rb_raise(rb_eArgError, "No Stylesheet");
  rbxsl = StringValue(rbxsl);
  if (!RSTRING(rbxsl)->len)
    rb_raise(rb_eArgError, "No Stylesheet");
  rbxroot = rb_iv_get(self, "@xroot");
  rbparams = check_params(rb_iv_get(self, "@xparams"));

  // Initialize our globals
  if (!NIL_P(rbxroot))
    g_xroot = StringValue(rbxroot);
  g_xtrack = RTEST(rb_iv_get(self, "@xtrack")) ? Qtrue : Qfalse;
  g_xfiles = rb_ary_new();
  g_xmsg = rb_ary_new();

  // Register callbacks and stuff
  my_register_xml();

  // Make sure our pointers are all NULL
  memset(&myPointers, '\0', sizeof(myPointers));

  // Build param array
  if (rbparams != Qnil)
    if (NULL==(myPointers.params=build_params(rbparams)))
      my_raise(self, &myPointers, rb_eNoMemError, "Cannot allocate parameter block");

  // Parse XSL
  if (looksLikeXML(rbxsl))
  {
    myPointers.docxsl = xmlParseMemory(RSTRING(rbxsl)->ptr, RSTRING(rbxsl)->len);
//    myPointers.docxsl = xmlReadMemory(RSTRING(rbxsl)->ptr, RSTRING(rbxsl)->len, ".", NULL, 0);
    if (myPointers.docxsl == NULL)
    {
      my_raise(self, &myPointers, rb_eSystemCallError, "XSL parsing error");
      return Qnil;
    }
    myPointers.xsl = xsltParseStylesheetDoc(myPointers.docxsl);
    if (myPointers.xsl == NULL)
    {
      my_raise(self, &myPointers, rb_eSystemCallError, "XSL stylesheet parsing error");
      return Qnil;
    }
  }
  else // xsl is a filename
  {
    myPointers.xsl = xsltParseStylesheetFile(RSTRING(rbxsl)->ptr);
    if (myPointers.xsl == NULL)
    {
      my_raise(self, &myPointers, rb_eSystemCallError, "XSL file loading error");
      return Qnil;
    }
  }

  // Parse XML 
  if (looksLikeXML(rbxml))
  {
    myPointers.docxml = xmlReadMemory(RSTRING(rbxml)->ptr, RSTRING(rbxml)->len, ".", NULL, xmlOptions);
    if (myPointers.docxml == NULL)
    {
      my_raise(self, &myPointers, rb_eSystemCallError, "XML parsing error");
      return Qnil;
    }
  }
  else // xml is a filename
  {
	  myPointers.docxml = xmlReadFile(RSTRING(rbxml)->ptr, NULL, xmlOptions);
    if (myPointers.docxml == NULL)
    {
      my_raise(self, &myPointers, rb_eSystemCallError, "XML file parsing error");
      return Qnil;
    }
  }

  // Apply stylesheet to xml
  myPointers.docres = xsltApplyStylesheet(myPointers.xsl, myPointers.docxml, (void*)myPointers.params);
  if (myPointers.docres == NULL)
  {
    my_raise(self, &myPointers, rb_eSystemCallError, "Stylesheet apply error");
    return Qnil;
  }
  
  xsltSaveResultToString(&(myPointers.docstr), &docstrlen, myPointers.docres, myPointers.xsl);
  if ( docstrlen >= 1 )
    rbout = rb_str_new2((char*)(myPointers.docstr));
  else
    rbout = Qnil;
  rb_iv_set(self, "@xres", rbout);
  rb_iv_set(self, "@xfiles", g_xfiles);
  rb_iv_set(self, "@xmsg", g_xmsg);

  // Clean up, no exception to raise
  my_raise(self, &myPointers, Qnil, NULL);
  return rbout;
}

// Use g_mutex to make sure our callbacks do not mess up the globals
// if the user is running several transforms in parallel threads
static VALUE in_sync(VALUE self)
{
  return rb_funcall(self, id.synchronize, 0);
}

VALUE xsl_process(VALUE self)
{
  rb_iterate(in_sync, g_mutex, xsl_process_real, self);
}

/*
 *     @xerr
 */
VALUE xsl_xerr_get( VALUE self )
{
  return rb_iv_get(self, "@xerr");
}

/*
 *     @xres
 */
VALUE xsl_xres_get( VALUE self )
{
  return rb_iv_get(self, "@xres");
}

/*
 *     @xmsg
 */
VALUE xsl_xmsg_get( VALUE self )
{
  return rb_iv_get(self, "@xmsg");
}

/*
 *     @xfiles
 */
VALUE xsl_xfiles_get( VALUE self )
{
  return rb_iv_get(self, "@xfiles");
}

/*
 *     @xparams
 */
VALUE xsl_xparams_set( VALUE self, VALUE xparams )
{
  // Check params and raise an exception if not happy
  check_params(xparams);
  // Store parameters
  return rb_iv_set(self, "@xparams", xparams);
}

VALUE xsl_xparams_get( VALUE self )
{
  return rb_iv_get(self, "@xparams");
}

/*
 *     @xroot
 */
VALUE xsl_xroot_set( VALUE self, VALUE xroot )
{
  // Throw an exception if xroot cannot be used as a string
  if (!NIL_P(xroot)) StringValue(xroot); 
  // Store param in @xroot
  rb_iv_set(self, "@xroot", xroot);
  
  return xroot;
}

VALUE xsl_xroot_get( VALUE self )
{
  return rb_iv_get(self, "@xroot");
}

/*
 *     @xtrack
 */
VALUE xsl_xtrack_set( VALUE self, VALUE xtrack )
{
  // @xtrack is true if param is neither Qnil nor QFalse
  rb_iv_set(self, "@xtrack", RTEST(xtrack) ? Qtrue : Qfalse);
  
  return xtrack;
}

VALUE xsl_xtrack_get( VALUE self )
{
  return rb_iv_get(self, "@xtrack");
}

/*
 *     @xml
 */
VALUE xsl_xml_set( VALUE self, VALUE xml )
{
  // Throw an exception if xml cannot be used as a string
  if (!NIL_P(xml)) StringValue(xml); 
  // Store param in @xml
  rb_iv_set(self, "@xml", xml);
  
  return xml;
}

VALUE xsl_xml_get( VALUE self )
{
  return rb_iv_get(self, "@xml");
}

/*
 *     @xsl
 */
VALUE xsl_xsl_set( VALUE self, VALUE xsl )
{
  // Throw an exception if xsl cannot be used as a string
  if (!NIL_P(xsl)) StringValue(xsl); 
  // Store param in @xsl
  rb_iv_set(self, "@xsl", xsl);
  
  return xsl;
}

VALUE xsl_xsl_get( VALUE self )
{
  return rb_iv_get(self, "@xsl");
}


static VALUE xsl_init(VALUE self)
{
  rb_iv_set(self, "@xml", Qnil);
  rb_iv_set(self, "@xsl", Qnil);
  rb_iv_set(self, "@xfiles", Qnil);
  rb_iv_set(self, "@xmsg", Qnil);
  rb_iv_set(self, "@xparams", Qnil);
  rb_iv_set(self, "@xroot", Qnil);
  rb_iv_set(self, "@xtrack", Qfalse);
  rb_iv_set(self, "@xerr", Qnil);

  return self;
}


VALUE mGorg;
VALUE cXSL;

/*
 *    Library Initialization
 */
void Init_xsl( void )
{
  mGorg = rb_define_module( "Gorg" );
  cXSL = rb_define_class_under( mGorg, "XSL", rb_cObject );

  // Get our lib global mutex
  rb_require("thread");
  g_mutex = rb_eval_string("Mutex.new");

  // Get method ID's
  id.include     = rb_intern("include?");
  id.to_a        = rb_intern("to_a");
  id.to_s        = rb_intern("to_s");
  id.length      = rb_intern("length");
  id.synchronize = rb_intern("synchronize");
  
  // Register lib global variables with ruby's GC
  rb_global_variable(&g_mutex);
  rb_global_variable(&g_xfiles);
  rb_global_variable(&g_xmsg);
  rb_global_variable(&g_xroot);

  rb_define_const( cXSL, "ENGINE_VERSION",    rb_str_new2(xsltEngineVersion) );
  rb_define_const( cXSL, "LIBXSLT_VERSION",   INT2NUM(xsltLibxsltVersion) );
  rb_define_const( cXSL, "LIBXML_VERSION",    INT2NUM(xsltLibxmlVersion) );
  rb_define_const( cXSL, "XSLT_NAMESPACE",    rb_str_new2(XSLT_NAMESPACE) );
  rb_define_const( cXSL, "DEFAULT_VENDOR",    rb_str_new2(XSLT_DEFAULT_VENDOR) );
  rb_define_const( cXSL, "DEFAULT_VERSION",   rb_str_new2(XSLT_DEFAULT_VERSION) );
  rb_define_const( cXSL, "DEFAULT_URL",       rb_str_new2(XSLT_DEFAULT_URL) );
  rb_define_const( cXSL, "NAMESPACE_LIBXSLT", rb_str_new2(XSLT_LIBXSLT_NAMESPACE) );

  rb_define_method( cXSL, "initialize", xsl_init, 0 );

  rb_define_method( cXSL, "xmsg",     xsl_xmsg_get,    0 ); // Return array of '%%GORG%%.*' strings returned by the XSL transform with <xsl:message>
  rb_define_method( cXSL, "xfiles",   xsl_xfiles_get,  0 ); // Return array of names of all files that libxml2 opened during last process
  rb_define_method( cXSL, "xparams",  xsl_xparams_get, 0 ); // Return hash of params
  rb_define_method( cXSL, "xparams=", xsl_xparams_set, 1 ); // Set hash of params to pass to the xslt processor {"name" => "value"...}
  rb_define_method( cXSL, "xroot",    xsl_xroot_get,   0 ); // Root dir where we should look for files with absolute path
  rb_define_method( cXSL, "xroot=",   xsl_xroot_set,   1 ); // See the root dir as a $DocumentRoot
  rb_define_method( cXSL, "xtrack?",  xsl_xtrack_get,  0 ); // Should I track the files that libxml2 opens
  rb_define_method( cXSL, "xtrack=",  xsl_xtrack_set,  1 ); // Track the files that libxml2 opens, or not
  rb_define_method( cXSL, "xml",      xsl_xml_get,     0 );
  rb_define_method( cXSL, "xml=",     xsl_xml_set,     1 );
  rb_define_method( cXSL, "xsl",      xsl_xsl_get,     0 );
  rb_define_method( cXSL, "xsl=",     xsl_xsl_set,     1 );
  rb_define_method( cXSL, "xerr",     xsl_xerr_get,    0 );
  rb_define_method( cXSL, "xres",     xsl_xres_get,    0 );
  rb_define_method( cXSL, "process",  xsl_process,     0 );
}
