package CGI::Compress::Gzip;

=head1 NAME

CGI::Compress::Gzip - CGI with automatically compressed output

=head1 LICENSE

Copyright Clotho Advanced Media Inc.

This software is released under the GNU Public License v2 by Clotho
Advanced Media, Inc.  See the "LICENSE" file, or visit
http://www.clotho.com/code/GPL

The definitive source of Clotho Advanced Media software is
http://www.clotho.com/code/

All of our software is also available under commercial license.  If
the GPL does not meet the needs of your project, please contact us at
info@clotho.com or visit the above URL.

We release open source software to help the world.  We hope that you
will enjoy this software, and we also hope and that you will hire us.
As authors of this software, we are best able to help you integrate it
into your project and to assist you with any problems.

=head1 SYNOPSIS

   use CGI::Compress::Gzip;
  
   my $cgi = new CGI::Compress::Gzip;
   print $cgi->header();
   print "<html> ...";

=head1 DESCRIPTION

[This is beta code, but we use it in our production Linux
environments.  See the CAVEATS section below for potential gotchas.
I've received reports that it fails under Windows.  Help!]

CGI::Compress::Gzip extends the CGI class to auto-detect whether the
client browser wants compressed output and, if so and if the script
chooses HTML output, apply gzip compression on any content header for
STDOUT.  This module is intended to be a drop-in replacement for
CGI.pm in a typical scripting environment.

Apache mod_perl users may wish to consider the Apache::Compress or
Apache::GzipChain modules, which allow more transparent output
compression than this module can provide.  However, as of this writing
those modules are more aggressive about compressing, regardless of
Content-Type.

=head2 Headers

At the time that a header is requested, CGI::Compress::Gzip checks the
HTTP_ACCEPT_ENCODING environment variable (passed by Apache).  If this
variable includes the flag "gzip" and the outgoing mime-type is
"text/*", then gzipped output is prefered.  [the default mime-type
selection of text/* can be changed by subclasses -- see below]  The
header is altered to add the "Content-Encoding: gzip" flag which
indicates that compression is turned on.

Naturally, it is crucial that the CGI application output nothing
before the header is printed.  If this is violated, things will go
badly.

=head2 Compression

When the header is created, this module sets up a new filehandle to
accept data.  STDOUT is redirected through that filehandle.  The new
filehandle passes data verbatim until it detects the end of the CGI
header.  At that time, it switches over to Gzip output for the
remainder of the CGI run.

Note that the Zlib library on which this code is ultimately based
requires a fileno for the output filehandle.  Where the output
filehandle is faked (i.e. in mod_perl), we instead use in-memory
compression.  This is more wasteful of RAM, but it is the only
solution I've found (and it is one shared by the Apache::* compression
modules).

Debugging note: if you set B<$CGI::Compress::Gzip::global_give_reason>
to a true value, then this module will add an HTTP header entry called
B<X-non-gzip-reason> with an explanation of why it chose not to gzip
the output stream.

=head2 Buffering

The Zlib library introduces latencies.  In some cases, this module may
delay output until the CGI object is garbage collected, presumably at
the end of the program.  This buffering can be detrimental to
long-lived programs which are supposed to have incremental output,
causing browser timeouts.  To compensate, compression is automatically
disabled when autoflush (i.e. the $| variable) is set to true.  Future
versions may try to enable autoflushing on the Zlib filehandles, if
possible [Help wanted].

=cut

require 5.005_62;
use strict;
use warnings;
use Carp;
use CGI;

our @ISA = qw(CGI);
our $VERSION = '0.19';

# Package globals

our $global_use_compression = 1; # user-settable
our $global_can_compress = undef; # 1 = yes, 0 = no, undef = don't know yet

# If true, add an outgoing HTTP header explaining why we are not
# compressing if gzip turns itself off.
our $global_give_reason = 0;

#==============================

=head1 CLASS METHODS

=over 4

=cut

#==============================

=item new <CGI-ARGS>

Create a new object.  This resets the environment before creating a
CGI.pm object.  This should not be called more than once per script
run!  All arguments are passed to the parent class.

=cut

sub new
{
   my $pkg = shift;

   $CGI::Compress::Gzip::wrapper::use_fh = undef;
   select STDOUT;
   my $self = $pkg->SUPER::new(@_);
   return $self;
}
#==============================

=item useCompression 1|0

Turn compression on/off for all CGI::Compress::Gzip objects.  If
turned on, compression will be used only if the prerequisite
compression libraries are available and if the client browser requests
compression.

=cut

sub useCompression
{
   my $pkg = shift;
   my $set = shift;

   $global_use_compression = $set;
   return $pkg;
}
#==============================

=back

=head1 INSTANCE METHODS

=over 4

=cut

#==============================

=item useFileHandle FILEHANDLE

Manually set the output filehandle.  Because of limitations of libz,
this MUST be a real filehandle (with valid results from fileno()) and
not a pseudo filehandle like IO::String.

If this is not set, STDOUT is used.

=cut

sub useFileHandle
{
   my $self = shift;
   my $fh = shift;

   $CGI::Compress::Gzip::wrapper::use_fh = $fh;
   return $self;
}
#==============================

=item isCompressibleType CONTENT-TYPE

Given a MIME type (with possible charset attached), return a boolean
indicating if this media type is a good candidate for compression.
This implementation is simply:

    return $type =~ /^text\//;

Subclasses may wish to override this method to apply different
criteria.

=cut

sub isCompressibleType
{
   my $self = shift;
   my $type = shift || "";

   return $type =~ /^text\//;
}
#==============================

=item header HEADER-ARGS

Return a CGI header with the compression flags set properly.  Returns
an empty string is a header has already been printed.

This method engages the Gzip output by fiddling with the default
output filehandle.  All subsequent output via usual Perl print() will
be automatically gzipped except for this header (which must go out as
plain text).

Any arguments will be passed on to CGI::header.  This method should
NOT be called if you don't want your header or STDOUT to be fiddled
with.

=cut

sub header
{
   my $self = shift;
   # further args passed on below
   
   if ($self->{'.header_printed'} && $self->{'.zlib_fh'})
   {
      return tied(${$self->{'.zlib_fh'}})->{pending_header};
   }

   my @args = (@_);
   my $compress = $self->_canCompress(\@args);

   my $header = $self->SUPER::header(@args);
   $self->_startCompression($header) if ($compress);
   return $header;
}
#==============================

# Enable the compression filehandle if:
#  - The mime-type is appropriate (text/* is the default)
#  - The programmer wants compression, indicated by the useCompression()
#    method
#  - Client wants compression, indicated by the Accepted-Encoding HTTP field
#  - The IO::Zlib compression library is available

sub _canCompress
{
   my $self = shift;
   my $header = shift;  # array ref

   my $compress = 1;
   my $reason = "";
   my @newheader;

   # Check programmer preference
   $compress &&= $global_use_compression;
   $reason ||= "programmer request" if (!$compress);

   $CGI::Compress::Gzip::wrapper::flush = $|; # save it in case we change it

   # Check buffering (disable if autoflushing)
   $compress &&= (!$CGI::Compress::Gzip::wrapper::flush);
   $reason ||= "programmer wants unbuffered output" if (!$compress);

   # Check that browser supports gzip
   my $acc = $ENV{HTTP_ACCEPT_ENCODING};
   $compress &&= ($acc && $acc =~ /\bgzip\b/i);
   $reason ||= "user agent does not want gzip" if (!$compress);

   # Check that the output will be HTML
   $compress &&= $header && ref($header);
   $reason ||= "no header to check" if (!$compress);

   my $content_type = "";
   if ($compress)
   {
      if (@$header && $header->[0] =~ /^[a-z]/)
      {
         # Using unkeyed version of arguments - convert to the keyed
         # version

         # arg order comes from the header() function in CGI.pm
         my @flags = qw(Content_Type Status Cookie Target Expires
                        NPH Charset Attachment P3P);
         for (my $i=0; $i < @$header; $i++)
         {
            if ($i < @flags)
            {
               push @newheader, "-".$flags[$i], $header->[$i];
            }
            else
            {
               # Extra args
               push @newheader, $header->[$i];
            }
         }
      }
      else
      {
         @newheader = (@$header);
      }

      my $encodingIndex = undef;
      for (my $i=0; $i < @newheader; $i++)
      {
         next if (!defined $newheader[$i]);
         if ($newheader[$i] =~ /^-?(?:Content[-_]Type|Type)$/i)
         {
            $content_type = $newheader[++$i];
         }
         elsif ($newheader[$i] =~ /^-?(?:Content[-_]Type|Type): (.*)$/i)
         {
            $content_type = $1;
         }
         elsif (($newheader[$i] =~ /^-?Status$/i && $newheader[++$i] =~ /(\d+)/) ||
                $newheader[$i] =~ /^-?Status:\s*(\d+)/i)
         {
            my $status = $1;
            if ($status != 200)
            {
               $compress = 0;
               last;
            }
         }
         elsif (($newheader[$i] =~ /^-?Content[-_]Encoding$/i && ++$i) ||
                $newheader[$i] =~ /^-?Content[-_]Encoding: $/i)
         {
            if ($newheader[$i] =~ /\bgzip\b/i)
            {
               # Already gzip compressed
               $compress = 0;
               last;
            }
            else
            {
               $encodingIndex = $i;
            }
         }
      }

      if ($compress)
      {
         if (defined $encodingIndex)
         {
            $newheader[$encodingIndex] =~ s/^(?:-?Content[-_]Encoding:\s*)/gzip, /mio
                or $newheader[$encodingIndex] = "gzip, " . $newheader[$encodingIndex];
         }
         else
         {
            push @newheader, "-Content_Encoding", "gzip";
         }
      }
   }
   $reason ||= "someone already requested gzip" if (!$compress);

   $content_type ||= "text/html";
   if (!$self->isCompressibleType($content_type))
   {
      # Not compressible media
      $compress = 0;
   }
   $reason ||= "incompatible content-type $content_type" if (!$compress);

   # Check that IO::Zlib is available
   if ($compress)
   {
      if (!defined $global_can_compress)
      {
         local $SIG{__WARN__} = 'DEFAULT';
         eval "require IO::Zlib";
         $global_can_compress = $@ ? 0 : 1;
      }
      $compress &&= $global_can_compress;
   }
   $reason ||= "IO::Zlib not found" if (!$compress);

   if ($compress)
   {
      @$header = @newheader;
   }
   else
   {
      push @$header, "-X_non_gzip_reason", $reason if ($global_give_reason);
   }

   return $compress;
}

sub _startCompression
{
   my $self = shift;
   my $header = shift;

   $CGI::Compress::Gzip::wrapper::use_fh ||= \*STDOUT;
   binmode $CGI::Compress::Gzip::wrapper::use_fh;

   my $filehandle = CGI::Compress::Gzip::wrapper->new($CGI::Compress::Gzip::wrapper::use_fh, "wb");
   if (!$filehandle)
   {
      carp "Failed to open Zlib output, reverting to uncompressed output";
      return undef;
   }
   
   # All output from here on goes to our new filehandle
   if ($CGI::Compress::Gzip::wrapper::flush && UNIVERSAL::can($filehandle, "autoflush"))
   {
      $filehandle->autoflush();
   }

   select $filehandle;

   $self->{'.zlib_fh'} = $filehandle;  # needed for destructor
   
   tied(${$self->{'.zlib_fh'}})->{pending_header} = $header;

   return $self;
}
#==============================

=item DESTROY

Override the CGI destructor so we can close the Gzip output stream, if
there is one open.

=cut

sub DESTROY
{
   my $self = shift;

   if ($self->{'.zlib_fh'})
   {
      $self->{'.zlib_fh'}->close() 
          or &croak("Failed to close the Zlib filehandle");
   }
   return $self->SUPER::DESTROY();
}
#==============================

package CGI::Compress::Gzip::wrapper;

=back

=head1 HELPER CLASS

CGI::Compress::Gzip also implements a helper class in package
CGI::Compress::Gzip::wrapper which subclasses IO::Zlib.  This helper
is needed to make sure that output is not compressed until the CGI
header is emitted.  This wrapper delays the ignition of the zlib
filter until it sees the exact same header generated by
CGI::Compress::Gzip::header() pass through it's WRITE() method.  If
you change the header before printing it, this class will throw an
exception.

This class hold one global variable representing the previous default
filehandle used before the gzip filter is put in place.  This
filehandle, usually STDOUT, is replaced after the gzip stream finishes
(which is usually when the CGI object goes out of scope and is
destroyed).

=cut

our @ISA = qw(IO::Zlib);

our $use_fh;

sub OPEN
{
   my $self = shift;

   # Delay opening until after the header is printed.
   $self->{openargs} = [@_];
   $self->{outtype} = undef;
   $self->{buffer} = "";
   return $self;
}

sub WRITE
{
   my $self = shift;
   my $buf = shift;
   my $length = shift;
   my $offset = shift;

   # Appropriated from IO::Zlib:
   &Carp::croak("bad LENGTH") unless ($length <= length($buf));
   &Carp::croak("OFFSET not supported") if (defined($offset) && $offset != 0);

   my $bytes = 0;
   my $header = $self->{pending_header};
   if ($header)
   {
      if (length($header) > $length)
      {
         $self->{pending_header} = substr($header, $length);
         $header = substr($header, 0, $length);
      }
      else
      {
         $self->{pending_header} = "";
      }
      if ($buf =~ s/^\Q$header//s)
      {
         no strict qw(refs);
         if (print $use_fh $header)
         {
            $bytes += length($header);
            $length -= length($header);
         }
         else
         {
            &Carp::croak("Failed to print the uncompressed CGI header");
         }
      }
      else
      {
         &Carp::croak("Expected to print the CGI header");
      }
   }
   if ($length)
   {
      if (!defined $self->{outtype})
      {
         my $fh = $self->{openargs}->[0];
         my $mod_perl = ($ENV{MOD_PERL} ||
                         ($ENV{GATEWAY_INTERFACE} &&
                          $ENV{GATEWAY_INTERFACE} =~ /^CGI-Perl\//));
         my $isglob = (ref($fh) && ref($fh) eq "GLOB" &&
                       defined $fh->fileno());
         my $isfilehandle = (ref($fh) && 
                             ref($fh) !~ /^GLOB|SCALAR|HASH|ARRAY|CODE$/ &&
                             $fh->can("fileno") &&
                             defined $fh->fileno());

         if ((!$mod_perl) && ($isglob || $isfilehandle)) 
         {
            # Finished printing header!
            # Complete delayed open
            if (!$self->SUPER::OPEN(@{$self->{openargs}}))
            {
               &Carp::croak("Failed to open the compressed output stream");
            }
            $self->{outtype} = "stream";
         }
         else
         {
            $self->{outtype} = "block";
         }
      }
      if ($self->{outtype} eq "stream")
      {
         $bytes += $self->SUPER::WRITE($buf, $length, $offset);
      }
      else
      {
         $self->{buffer} .= $buf;
         $bytes += length $buf;
      }
   }
   return $bytes;
}

sub CLOSE
{
   # Debugging:
   #$SIG{__DIE__} = sub {print STDERR "die: ".join("", @_)};

   my $self = shift;

   $use_fh = undef;
   select STDOUT;
   my $result;
   if ($self->{outtype} && $self->{outtype} eq "stream")
   {
      $result = $self->SUPER::CLOSE();
      if (!$result)
      {
         &Carp::confess("Failed to close gzip $!");
      }
   }
   else
   {
      print STDOUT Compress::Zlib::memGzip($self->{buffer});
      $result = 1;
   }
   return $result;
}

1;
__END__

=head1 CAVEATS

=head2 Windows

This module fails tests specifically under Windows in ways I do not
understand, as reported by CPANPLUS testers.  There is some problem
with my IO::Zlib tests.  If anyone knows about IO::Zlib failures or
caveats on Windows, please let me know.  It *might* be related to
binmode, but I have not tested this theory.

=head2 Apache::Registry

Under Apache::Registry, global variables may not go out of scope in
time.  This may causes timing bugs, since this module makes use of
the DESTROY() method.  To avoid this issue, make sure your CGI
object is stored in a scoped variable.

   # BROKEN CODE
   use CGI::Compress::Gzip;
   $q = CGI::Compress::Gzip->new;
   print $q->header;
   print "Hello, world\n";
   
   # WORKAROUND CODE
   use CGI::Compress::Gzip;
   do {
     my $q = CGI::Compress::Gzip->new;
     print $q->header;
     print "Hello, world\n";
   }

=head2 Filehandles

This module works by changing the default filehandle.  It does not
change STDOUT at all.  As a consequence, your programs should call
C<print> without a filehandle argument.

   # BROKEN CODE
   use CGI::Compress::Gzip;
   my $q = CGI::Compress::Gzip->new;
   print STDOUT $q->header;
   print STDOUT "Hello, world\n";
   
   # WORKAROUND CODE
   use CGI::Compress::Gzip;
   my $q = CGI::Compress::Gzip->new;
   print $q->header;
   print "Hello, world\n";

Future versions may steal away STDOUT and replace it with the
compression filehandle, but that seemed too risky for this version.

=head1 SEE ALSO

CGI::Compress::Gzip depends on CGI and IO::Zlib.  Similar
functionality is available from mod_gzip, Apache::Compress or
Apache::GzipChain, however all of those require changes to the
webserver's configuration.

=head1 AUTHOR

Clotho Advanced Media, I<cpan@clotho.com>

=head1 THANKS

Clotho greatly appeciates the assistance and feedback the community
has extended to help refine this module.

Thanks to Rhesa Rozendaal who noticed the -Type omission in v0.17.

Thanks to Laga Mahesa who did some Windows testing and
expirimentation.

Thanks to Slaven Rezic who 1) found several header handling bugs, 2)
discovered the Apache::Registry and Filehandle caveats, and 3)
provided a patch incorporated into v0.17.

Thanks to Jan Willamowius who found a header handling bug.

Thanks to Andreas J. Koenig and brian d foy for module naming advice.

=head1 HELP WANTED

If you like this module, please help by testing on Windows or in a
FastCGI environment, since I have neither available for easy testing.
