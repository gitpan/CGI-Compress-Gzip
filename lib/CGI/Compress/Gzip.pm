package CGI::Compress::Gzip;

use 5.006;
use warnings;
use strict;
use English qw(-no_match_vars);

use CGI::Compress::Gzip::FileHandle;

use base qw(CGI);
our $VERSION = '0.21';

# Package globals - testing and debugging flags

# These should only be used for extreme circumstances (e.g. testing)
our $global_use_compression = 1;     # user-settable
our $global_can_compress    = undef; # 1 = yes, 0 = no, undef = don't know yet

# If true, add an outgoing HTTP header explaining why we are not
# compressing if gzip turns itself off.
our $global_give_reason = 0;

=head1 NAME

CGI::Compress::Gzip - CGI with automatically compressed output

=head1 LICENSE

Copyright 2005 Clotho Advanced Media, Inc., <cpan@clotho.com>

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

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

=head1 CLASS METHODS

=over 4

=item new <CGI-ARGS>

Create a new object.  This resets the environment before creating a
CGI.pm object.  This should not be called more than once per script
run!  All arguments are passed to the parent class.

=cut

sub new
{
   my $pkg = shift;

   select STDOUT;
   my $self = $pkg->SUPER::new(@_);
   $self->{'.CGIgz'} = {
      ext_fh          => undef,
      zlib_fh         => undef,
      header_done     => 0,
      use_compression => undef,
   };
   return $self;
}

=item useCompression 1|0

This can be used as a class method or an instance method.  The former
is included for backward compatibility, and is NOT recommended.  As a
class method, this changes the default value.  As an instance method
it affects only the specified instance.

Turn compression on/off for the target.  If turned on, compression
will be used only if the prerequisite compression libraries are
available and if the client browser requests compression.

Defaults to on.

=cut

sub useCompression
{
   my $pkg_or_self = shift;
   my $set = shift;

   if (ref $pkg_or_self)
   {
      $pkg_or_self->{'.CGIgz'}->{use_compression} = $set ? 1 : 0;
   }
   else
   {
      $global_use_compression = $set ? 1 : 0;
   }
   return $pkg_or_self;
}

=back

=head1 INSTANCE METHODS

=over 4

=item useFileHandle FILEHANDLE

Manually set the output filehandle.  Because of limitations of libz,
this MUST be a real filehandle (with valid results from fileno()) and
not a pseudo filehandle like IO::String.

If this is not set, STDOUT is used.

=cut

sub useFileHandle
{
   my $self = shift;
   my $fh   = shift;

   $self->{'.CGIgz'}->{ext_fh} = $fh;
   return $self;
}

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
   my $type = shift || q{};

   return $type =~ /^text\//;
}

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
   my @args     = (@_);

   my $compress = $self->_canCompress(\@args);

   my $header = $self->SUPER::header(@args);
   if (!defined $header)   # workaround for problem found on 5.6.0 on Linux
   {
      $header = "";
   }

   if (!$self->{'.CGIgz'}->{header_done}++ && $compress)
   {
      $self->_startCompression($header);
   }
   return $header;
}

# Enable the compression filehandle if:
#  - The mime-type is appropriate (text/* is the default)
#  - The programmer wants compression, indicated by the useCompression()
#    method
#  - Client wants compression, indicated by the Accepted-Encoding HTTP field
#  - The IO::Zlib compression library is available

sub _canCompress
{
   my $self   = shift;
   my $header = shift;    # array ref

   my $compress;
   my $reason = q{};
   my @newheader;

   my $settings = $self->{'.CGIgz'};

   # Check programmer preference
   $compress = (defined $settings->{use_compression} ?
                $settings->{use_compression} : $global_use_compression) ? 1 : 0;
   if (!$compress)
   {
      $reason = 'programmer request';
   }
   else
   {

      # save it in case we change it
      $settings->{flush} = $OUTPUT_AUTOFLUSH;

      # Check buffering (disable if autoflushing)
      $compress = !$settings->{flush} ? 1 : 0;
      if (!$compress)
      {
         $reason = 'programmer wants unbuffered output';
      }
      else
      {

         # Check that browser supports gzip
         my $acc = $ENV{HTTP_ACCEPT_ENCODING};
         $compress = $acc && $acc =~ /\bgzip\b/i ? 1 : 0;
         if (!$compress)
         {
            $reason = 'user agent does not want gzip';
         }
         else
         {

            # Parse the header data and look for indicators of compressibility:
            #  * appropriate content type
            #  * already set for compression
            #  * HTTP status not 200

            my $content_type;

            # This search reproduces the header parsing done by CGI.pm
            if (@$header && $header->[0] =~ /^[a-z]/)
            {

               # Using unkeyed version of arguments - convert to the keyed
               # version

               # arg order comes from the header() function in CGI.pm
               my @flags = qw(
                  Content_Type Status Cookie Target Expires
                  NPH Charset Attachment P3P
               );
               for (my $i = 0; $i < @$header; $i++)
               {
                  if ($i < @flags)
                  {
                     push @newheader, q{-} . $flags[$i], $header->[$i];
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
               @newheader = @$header;
            }

            # gets set if we find an existing encoding directive
            my $encoding_index = undef;

          HEADER_DATUM:
            for (my $i = 0; $i < @newheader; $i++)
            {
               next HEADER_DATUM if (!defined $newheader[$i]);
               if ($newheader[$i] =~ /^-?(?:Content[-_]Type|Type)(.*)$/i)
               {
                  $content_type = $1;
                  if ($content_type !~ s/^:\s*//)
                  {
                     $content_type = $newheader[++$i];
                  }
               }
               elsif ($newheader[$i] =~ /^-?Status(.*)$/i)
               {
                  my $content = $1;
                  if ($content !~ s/^:\s*//)
                  {
                     $content = $newheader[++$i];
                  }
                  my ($status) = $content =~ /^(\d+)/;
                  if (!defined $status || $status ne "200")
                  {
                     $compress = 0;
                     $reason   = 'HTTP status not 200';
                     last HEADER_DATUM;
                  }
               }
               elsif ($newheader[$i] =~ /^-?Content[-_]Encoding(.*)$/i)
               {
                  my $content = $1;
                  if ($content !~ s/^:\s*//)
                  {
                     $content = $newheader[++$i];
                  }
                  $encoding_index = $i;

                  if ($content =~ /\bgzip\b/i)
                  {
                     # Already gzip compressed
                     $compress = 0;
                     $reason   = 'someone already requested gzip';
                     last HEADER_DATUM;
                  }
               }
            }

            if ($compress)
            {
               if (defined $encoding_index)
               {
                  # prepend gzip encoding to the existing encoding list
                  $newheader[$encoding_index] =~ s/^((?:-?Content[-_]Encoding:\s*)?)/$1gzip, /mio;
               }
               else
               {
                  push @newheader, '-Content_Encoding', 'gzip';
               }

               $content_type ||= 'text/html';
               if (!$self->isCompressibleType($content_type))
               {
                  # Not compressible media
                  $compress = 0;
                  $reason   = "incompatible content-type $content_type";
               }
               else
               {

                  # Check that IO::Zlib is available
                  if (!defined $global_can_compress)
                  {
                     local $SIG{__WARN__} = 'DEFAULT';
                     local $SIG{__DIE__}  = 'DEFAULT';
                     eval { require IO::Zlib; };
                     $global_can_compress = $EVAL_ERROR ? 0 : 1;
                  }
                  $compress = $global_can_compress;
                  if (!$compress)
                  {
                     $reason = 'IO::Zlib not found';
                  }
                  else
                  {
                     @$header = @newheader;
                  }
               }
            }
         }
      }
   }

   if ($global_give_reason && $reason)
   {
      push @$header, '-X_non_gzip_reason', $reason;
   }

   #warn $reason if ($reason);

   return $compress;
}

sub _startCompression
{
   my $self   = shift;
   my $header = shift;

   my $settings = $self->{'.CGIgz'};
   $settings->{ext_fh} ||= \*STDOUT;
   binmode $settings->{ext_fh};

   my $filehandle = CGI::Compress::Gzip::FileHandle->new($settings->{ext_fh}, 'wb');
   if (!$filehandle)
   {
      warn 'Failed to open Zlib output, reverting to uncompressed output';
      return;
   }

   # All output from here on goes to our new filehandle

   ## Autoflush makes no sense since compression is disabled if autoflush is on
   #if ($filehandle->can('autoflush'))
   #{
   #   $filehandle->autoflush();
   #}

   select $filehandle;

   $settings->{zlib_fh} = $filehandle;    # needed for destructor

   my $tied = tied $$filehandle;
   $tied->{pending_header} = $header;

   return $self;
}

=item DESTROY

Override the CGI destructor so we can close the Gzip output stream, if
there is one open.

=cut

sub DESTROY
{
   my $self = shift;

   if ($self->{'.CGIgz'}->{zlib_fh})
   {
      $self->{'.CGIgz'}->{zlib_fh}->close()
          or die 'Failed to close the Zlib filehandle';
   }
   if ($self->{'.CGIgz'}->{ext_fh})
   {
      select $self->{'.CGIgz'}->{ext_fh};
   }

   return $self->SUPER::DESTROY();
}

1;
__END__

=back

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

=head2 Header Munging

When sending compressed output, the HTTP headers must remain
uncompressed.  So, this module goes to great effort to keep the
headers and body separate.  That has led to CGI::header() emulation
code that is a little brittle.  Most potential problems arise because
STDOUT gets tweaked as soon as header() is called.

If you use the CGI.pm header() API as specified in CGI.pm, then all
should go well.  But if you do anything unusual, this module may
break.  For example:

   # BROKEN CODE
   use CGI::Compress::Gzip;
   my $q = CGI::Compress::Gzip->new;
   print "Set-Cookie: foo=bar\n" . $q->header;
   print "Hello, world\n";

   # WORKAROUND 1 (preferred)
   use CGI::Compress::Gzip;
   my $q = CGI::Compress::Gzip->new;
   print $q->header("-Set_Cookie" => "foo=bar");
   print "Hello, world\n";

   # WORKAROUND 2
   use CGI::Compress::Gzip;
   my $q = CGI::Compress::Gzip->new;
   print "Set-Cookie: foo=bar\n";
   print $q->header;
   print "Hello, world\n";

Future versions may try to parse the header to look for its end rather
than insisting that the printed version match the version returned by
header().

=head1 SEE ALSO

CGI::Compress::Gzip depends on CGI and IO::Zlib.  Similar
functionality is available from mod_gzip, Apache::Compress or
Apache::GzipChain, however all of those require changes to the
webserver's configuration.

=head1 AUTHOR

Clotho Advanced Media, I<cpan@clotho.com>

Primary developer: Chris Dolan

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
