package CGI::Compress::Gzip::FileHandle;

use 5.006;
use warnings;
use strict;
use English qw(-no_match_vars);

use base qw(IO::Zlib);
our $VERSION = '0.22';

=for stopwords zlib

=head1 NAME

CGI::Compress::Gzip::FileHandle - CGI::Compress::Gzip helper package

=head1 LICENSE

Copyright 2006 Clotho Advanced Media, Inc., <cpan@clotho.com>

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SYNOPSIS

   use CGI::Compress::Gzip;
  
   my $cgi = new CGI::Compress::Gzip;
   print $cgi->header();
   print "<html> ...";

=head1 DESCRIPTION

This is intended for internal use only!  Use CGI::Compress::Gzip
instead.

This CGI::Compress::Gzip helper class subclasses IO::Zlib.  It is 
is needed to make sure that output is not compressed until the CGI
header is emitted.  This filehandle delays the ignition of the zlib
filter until it sees the exact same header generated by
CGI::Compress::Gzip::header() pass through it's WRITE() method.  If
you change the header before printing it, this class will throw an
exception.

This class holds one global variable representing the previous default
filehandle used before the gzip filter is put in place.  This
filehandle, usually STDOUT, is replaced after the gzip stream finishes
(which is usually when the CGI object goes out of scope and is
destroyed).

=head1 FUNCTIONS

=over

=item OPEN

Overrides IO::Zlib::OPEN.  This method doesn't actually do anything --
it just stores it's arguments for a later call to SUPER::OPEN in
WRITE().  The reason is that we may not have seen the header yet, so
we don't yet know whether to compress output.

=cut

sub OPEN
{
   my $self = shift;

   # Delay opening until after the header is printed.
   $self->{out_fh}         = shift;
   $self->{openargs}       = [@_];
   $self->{outtype}        = undef;
   $self->{buffer}         = q{};
   $self->{pending_header} = q{};
   return $self;
}

=item WRITE buffer, length, offset

Emit the uncompressed header followed by the compressed body.

=cut

sub WRITE
{
   my $self   = shift;
   my $buf    = shift;
   my $length = shift;
   my $offset = shift;

   # Appropriated from IO::Zlib:
   if ($length > length $buf)
   {
      die 'bad LENGTH';
   }
   if (defined $offset && $offset != 0)
   {
      die 'OFFSET not supported';
   }

   my $bytes = 0;
   if ($self->{pending_header})
   {
      # Side effects: $buf and $self->{pending_header} are trimmed
      $bytes = $self->_print_header(\$buf, $length);
      $length -= $bytes;
   }
   return $bytes if (!$length);  # if length is zero, there's no body content to print

   if (!defined $self->{outtype})
   {
      # Determine whether we can stream data to the output filehandle
      
      # default case: no, cannot stream
      $self->{outtype} = 'block';

      # Mod perl already does funky filehandle stuff, so don't stream
      my $is_mod_perl = ($ENV{MOD_PERL} ||
                         ($ENV{GATEWAY_INTERFACE} &&
                          $ENV{GATEWAY_INTERFACE} =~ m/ \A CGI-Perl\/ /xms));

      my $type = ref $self->{out_fh};

      if (!$is_mod_perl && $type)
      {
         my $is_glob = $type eq 'GLOB' && defined $self->{out_fh}->fileno();
         my $is_filehandle = ($type !~ m/ \A GLOB|SCALAR|HASH|ARRAY|CODE \z /xms &&
                              $self->{out_fh}->can('fileno') &&
                              defined $self->{out_fh}->fileno());

         if ($is_glob || $is_filehandle)
         {
            # Complete delayed open
            if (!$self->SUPER::OPEN($self->{out_fh}, @{$self->{openargs}}))
            {
               die 'Failed to open the compressed output stream';
            }
               
            $self->{outtype} = 'stream';
         }
      }
   }

   if ($self->{outtype} eq 'stream')
   {
      $bytes += $self->SUPER::WRITE($buf, $length, $offset);
   }
   else
   {
      $self->{buffer} .= $buf;
      $bytes += length $buf;
   }

   return $bytes;
}

sub _print_header
{
   my $self = shift;
   my $buf = shift;
   my $length = shift;

   my $header = $self->{pending_header};
   if ($length < length $header)
   {
      $self->{pending_header} = substr $header, $length;
      $header = substr $header, 0, $length;
   }
   else
   {
      $self->{pending_header} = q{};
   }

   if (${$buf} !~ s/ \A \Q$header\E //xms)
   {
      die 'Expected to print the CGI header';
   }

   my $out_fh = $self->{out_fh};
   if (!print {$out_fh} $header)
   {
      die 'Failed to print the uncompressed CGI header';
   }
   
   return length $header;
}

=item CLOSE

Flush the compressed output.

=cut

sub CLOSE
{
   my $self = shift;

   my $out_fh = $self->{out_fh};
   $self->{out_fh} = undef;    # clear it, so we can't write to it after this method ends

   my $result;
   if ($self->{outtype} && $self->{outtype} eq 'stream')
   {
      $result = $self->SUPER::CLOSE();
      if (!$result)
      {
         die "Failed to close gzip $OS_ERROR";
      }
   }
   else
   {
      print {$out_fh} Compress::Zlib::memGzip($self->{buffer});
      $result = 1;
   }

   return $result;
}

1;
__END__

=back

=head1 AUTHOR

Clotho Advanced Media, I<cpan@clotho.com>

Primary developer: Chris Dolan

=cut