#!/usr/bin/perl -w

use strict;
use warnings;
use File::Temp qw(tempfile);
use IO::Zlib;
use Compress::Zlib;
use English qw(-no_match_vars);

BEGIN
{ 
   use Test::More tests => 56;
   use_ok('CGI::Compress::Gzip');
}

# This module behaves differently whether autoflush is on or off
# Make sure it is off
$OUTPUT_AUTOFLUSH = 0;

my $compare = 'Hello World!';  # expected output

# Have to use a temp file since Compress::Zlib doesn't like IO::String
my ($testfh, $testfile) = tempfile(UNLINK => 1);
close $testfh;

## Zlib sanity tests

my $zcompare = Compress::Zlib::memGzip($compare);
my $testbuf = $zcompare;
$testbuf = Compress::Zlib::memGunzip($testbuf);
is ($testbuf, $compare, 'Compress::Zlib double-check');

{
   local *FILE1;
   open FILE1, '>', $testfile or die 'Cannot write a temp file';
   binmode FILE1;
   local *STDOUT = *FILE1;
   my $fh = IO::Zlib->new(\*FILE1, 'wb');
   print $fh $compare;
   close $fh;
   close FILE1;

   my $in_fh;
   open $in_fh, '<', $testfile or die 'Cannot read temp file';
   binmode $in_fh;
   local $INPUT_RECORD_SEPARATOR = undef;
   my $out = <$in_fh>;
   close $in_fh;
   is($out, $zcompare, 'IO::Zlib test');
}

## Header tests

{
   my $dummy = CGI::Compress::Gzip->new();

   ok(!$dummy->isCompressibleType(), 'compressible types');
   ok($dummy->isCompressibleType('text/html'), 'compressible types');
   ok($dummy->isCompressibleType('text/plain'), 'compressible types');
   ok(!$dummy->isCompressibleType('image/jpg'), 'compressible types');
   ok(!$dummy->isCompressibleType('application/octet-stream'), 'compressible types');
 
   {
      local $ENV{HTTP_ACCEPT_ENCODING} = '';
      my @headers;
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers], [0, []], 'header test - env');
   }

   {
      local $ENV{HTTP_ACCEPT_ENCODING} = 'bzip2';
      my @headers;
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers], [0, []], 'header test - env');
   }

   # For the rest of the tests, pretend browser told us to turn on gzip
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   {
      my @headers;
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers], [1, ['-Content_Encoding', 'gzip']], 'header test - env');
   }

   {
      local $CGI::Compress::Gzip::global_give_reason = 1;
      my @headers;
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers], [1, ['-Content_Encoding', 'gzip']], 'header test - reason');
   }

   # Turn off compression
   CGI::Compress::Gzip->useCompression(0);
   {
      my @headers;
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers], [0, []], 'header test - override');
   }
   CGI::Compress::Gzip->useCompression(1);

   # Turn off compression
   $dummy->useCompression(0);
   {
      my @headers;
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers], [0, []], 'header test - override');
   }
   $dummy->useCompression(1);

   {
      local $OUTPUT_AUTOFLUSH = 1;
      my @headers;
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers], [0, []], 'header test - autoflush');
   }

   {
      my @headers = ('text/plain');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [1, ['-Content_Type', 'text/plain', '-Content_Encoding', 'gzip']],
                'header test - type');
   }

   {
      my @headers = ('-Content_Type', 'text/plain');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [1, ['-Content_Type', 'text/plain', '-Content_Encoding', 'gzip']],
                'header test - type');
   }

   {
      my @headers = ('Content_Type', 'text/plain');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [1, ['Content_Type', 'text/plain', '-Content_Encoding', 'gzip']],
                'header test - type');
   }

   {
      my @headers = ('-type', 'text/plain');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [1, ['-type', 'text/plain', '-Content_Encoding', 'gzip']],
                'header test - type');
   }

   {
      my @headers = ('Content_Type: text/plain');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [1, ['Content_Type: text/plain', '-Content_Encoding', 'gzip']],
                'header test - type');
   }

   {
      my @headers = ('Content_Type: image/gif');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [0, ['Content_Type: image/gif']],
                'header test - type');
   }

   {
      my @headers = ('-Content_Encoding', 'foo');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [1, ['-Content_Encoding', 'gzip, foo']],
                'header test - encoding');
   }

   {
      my @headers = ('-Content_Encoding', 'gzip');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [0, ['-Content_Encoding', 'gzip']],
                'header test - encoding');
   }

   {
      my @headers = ('Content-Encoding: foo');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [1, ['Content-Encoding: gzip, foo']],
                'header test - encoding');
   }

   {
      my @headers = ('-Status', '200');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [1, ['-Status', '200', '-Content_Encoding', 'gzip']],
                'header test - status');
   }

   {
      my @headers = ('Status: 200');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [1, ['Status: 200', '-Content_Encoding', 'gzip']],
                'header test - status');
   }

   {
      my @headers = ('Status: 200 OK');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [1, ['Status: 200 OK', '-Content_Encoding', 'gzip']],
                'header test - status');
   }

   {
      my @headers = ('Status: 500');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [0, ['Status: 500']],
                'header test - status');
   }

   {
      my @headers = ('-Status', 'junk');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [0, ['-Status', 'junk']],
                'header test - status');
   }

   {
      my @headers = ('Status: junk');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [0, ['Status: junk']],
                'header test - status');
   }

   {
      my @headers = ('-Irrelevent', '1');
      my ($compress, $reason) = $dummy->_can_compress(\@headers);
      is_deeply([$compress, \@headers],
                [1, ['-Irrelevent', '1', '-Content_Encoding', 'gzip']],
                'header test - other');
   }
}

## Tests that are as real-life as we can manage

# Turn off compression
ok(CGI::Compress::Gzip->useCompression(0), 'Turn off compression');

my $redir = 'http://www.foo.com/';

my $interp = "$^X -Iblib/arch -Iblib/lib";
$interp .= ' -MDevel::Cover' if (defined $Devel::Cover::VERSION);
my $basecmd = "$interp t/testhelp";

# Get CGI header for comparison in basic case
my $compareheader = CGI->new('')->header();

# no compression
{
   my $out = `$basecmd simple "$compare"`;
   ok($out !~ s/Content-[Ee]ncoding: gzip\r?\n//si && 
      $out !~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi, 
      'CGI template (header encoding text)');
   is($out, $compareheader.$compare, 'CGI template (body test)');
}

# no body
{
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   my $zempty = Compress::Zlib::memGzip(q{});

   my $out = `$basecmd empty "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//si ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi,
      'no body (header encoding text)');
   is($out, $compareheader.$zempty, 'no body (body test)');
}

# CGI and compression
{
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   my $out = `$basecmd simple "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//si ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi,
      'Gzipped CGI template (header encoding text)');
   is($out, $compareheader.$zcompare, 'Gzipped CGI template (body test)');
}

# CGI with charset and compression
{
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   my $header = CGI->new('')->header(-Content_Type => 'text/html; charset=UTF-8');

   my $out = `$basecmd charset "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//si ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi,
      'Gzipped CGI template with charset (header encoding text)');
   is($out, $header.$zcompare, 
      'Gzipped CGI template with charset (body test)');
}

# CGI with arguments
{
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   my $header = CGI->new('')->header(-Type => 'foo/bar');

   my $out = `$basecmd type "$compare"`;
   ok($out !~ s/Content-[Ee]ncoding: gzip\r?\n//si &&
      $out !~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi,
      'Un-Gzipped with -Type flag (argument processing text)');
   is($out, $header.$compare, 
      'Un-Gzipped with -Type flag (body test)');
}

# CGI redirection and compression
{
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   my $header = CGI->new('')->redirect($redir);

   my $out = `$basecmd redirect "$redir"`;
   ok($out !~ s/Content-[Ee]ncoding: gzip\r?\n//si && 
      $out !~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi, 
      'CGI redirect (header encoding text)');
   is($out, $header, 'CGI redirect (body test)');
}

# unbuffered CGI
{
   my $out = `$basecmd simple "$compare"`;
   ok($out !~ s/Content-[Ee]ncoding: gzip\r?\n//si && 
      $out !~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi, 
      'unbuffered CGI (header encoding text)');
   is($out, $compareheader.$compare, 'unbuffered CGI (body test)');
}

# Simulated mod_perl
{
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';
   my $out = `$basecmd mod_perl "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//si ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi,
      'mod_perl simulation (header encoding text)');
   is($out, $compareheader.$zcompare, 'mod_perl simulation (body test)');
}

# Double print header
{
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';
   my $out = `$basecmd doublehead "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//si ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi,
      'double header (header encoding text)');
   is($out, $compareheader.$zcompare, 'double header (body test)');
}

# redirected filehandle
SKIP: {
   
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   my $out = `$basecmd fh1 "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//si ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi,
      'filehandle (header encoding text)');
   is($out, $compareheader.$zcompare, 'filehandle (body test)');
}

# redirected filehandle
SKIP: {
   skip('Explicit use of filehandles not yet supported', 2);
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   my $out = `$basecmd fh2 "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//si ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi,
      'filehandle (header encoding text)');
   is($out, $compareheader.$zcompare, 'filehandle (body test)');
}

# redirected filehandle
SKIP: {
   skip('Explicit use of filehandles not yet supported', 2);
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   my $out = `$basecmd fh3 "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//si ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi,
      'filehandle (header encoding text)');
   is($out, $compareheader.$zcompare, 'filehandle (body test)');
}
