package CGI::Compress::Gzip;

=head1 NAME

CGI::Compress::Gzip - CGI with automatically compressed output

=head1 SYNOPSIS

  use CGI::Compress::Gzip;

  my $cgi = new CGI::Compress::Gzip;
  print $cgi->header();
  print "<html> ...";

=head1 DESCRIPTION

[This is still alpha code, but it works in some environments.  See
README for caveats.  I've received reports that it fails under
Windows.  Help!]

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
"text/*", then gzipped output is prefered.  The header is altered to
add the "Content-Encoding: gzip" flag which indicates that compression
is turned on.

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

=cut

require 5.005_62;
use strict;
use warnings;
use Carp;
use CGI;

our @ISA = qw(CGI);
our $VERSION = '0.10';

# Package globals

our $global_use_compression = 1; # user-settable
our $global_can_compress = undef; # 1 = yes, 0 = no, undef = don't know yet

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
#  - The output is text/*
#  - The programmer wants compression, indicated by the useCompression()
#    method
#  - Client wants compression, indicated by the Accepted-Encoding HTTP field
#  - The IO::Zlib compression library is available

sub _canCompress
{
   my $self = shift;
   my $header = shift;  # array ref

   my $compress = 1;

   # Check programmer preference
   $compress &&= $global_use_compression;
   #print STDERR "global\n" if ($compress);

   # Check that browser supports gzip
   my $acc = $ENV{HTTP_ACCEPT_ENCODING};
   $compress &&= ($acc && $acc =~ /\bgzip\b/i);
   #print STDERR "accept\n" if ($compress);

   # Check that the output will be HTML
   $compress &&= $header && ref($header);
   #print STDERR "header\n" if ($compress);

   if ($compress)
   {
      my $encodingIndex = undef;
      for (my $i=0; $i < @$header; $i++)
      {
         if ($i == 0 || 
             ($header->[$i] =~ /^-?Content[-_]Type$/i && ++$i) ||
             $header->[$i] =~ /^-?Content[-_]Type: $/i)
         {
            if ($header->[$i] !~ /\btext\/\w+/)
            {
               # Not text output
               $compress = 0;
               last;
            }
         }
         elsif (($header->[$i] =~ /^-?Content[-_]Encoding$/i && ++$i) ||
             $header->[$i] =~ /^-?Content[-_]Encoding: $/i)
         {
            if ($header->[$i] =~ /\bgzip\b/i)
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
            $header->[$encodingIndex] =~ s/^(?:-?Content[-_]Encoding:\s*)/gzip, /mio
                or $header->[$encodingIndex] = "gzip, " . $header->[$encodingIndex];
         }
         else
         {
            push @$header, "-Content_Encoding", "gzip";
         }
      }
   }
   #print STDERR "header2\n" if ($compress);

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
   #print STDERR "IO::Zlib\n" if ($compress);

   return $compress;
}

sub _startCompression
{
   my $self = shift;
   my $header = shift;

   $CGI::Compress::Gzip::wrapper::use_fh ||= \*STDOUT;
   
   my $filehandle = CGI::Compress::Gzip::wrapper->new($CGI::Compress::Gzip::wrapper::use_fh, "wb");
   if (!$filehandle)
   {
      carp "Failed to open Zlib output, reverting to uncompressed output";
      return undef;
   }
   
   # All output from here on goes to our new filehandle
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
header is emitted.  This wrappers delays the ignition of the zlib
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

=head1 TO DO

* Fix under Windows (MinGW?)  Help!  I'm a Mac/Linux guy.

* test in FastCGI environments

* Handle errors more gracefully in WRITE()

* Better detection of when output is not a real file handle

* Documentation and cleanup of the helper class

=head1 SEE ALSO

CGI::Compress::Gzip depends on CGI and IO::Zlib.  Related functionality is
available from Apache::Compress or Apache::GzipChain.

=head1 AUTHOR

Chris Dolan, Clotho Advanced Media, I<chris@clotho.com>

=head1 LICENSE

GPLv2, see the COPYING file in this distribution.
