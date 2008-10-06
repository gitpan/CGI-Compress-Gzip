#!/usr/bin/perl -w  ## no critic (ProhibitExcessMainComplexity)

## no critic (ProhibitBacktickOperators)
## no critic (ProhibitCommentedOutCode)
## no critic (ProhibitQuotedWordLists)
## no critic (ProhibitLocalVars)

use 5.006;
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
close $testfh or die;

## Zlib sanity tests

my $zcompare = Compress::Zlib::memGzip($compare);
my $testbuf = $zcompare;
$testbuf = Compress::Zlib::memGunzip($testbuf);
is ($testbuf, $compare, 'Compress::Zlib double-check');

{
   ## no critic (ProhibitBarewordFileHandles,RequireInitializationForLocalVars)
   local *OUT_FILE;
   open OUT_FILE, '>', $testfile or die 'Cannot write a temp file';
   binmode OUT_FILE;
   local *STDOUT = *OUT_FILE;
   my $fh = IO::Zlib->new(\*OUT_FILE, 'wb') or die;
   print {$fh} $compare;
   close $fh or die;
   close OUT_FILE and diag('Unexpected success closing already closed filehandle') or q{};

   my $in_fh;
   open $in_fh, '<', $testfile or die 'Cannot read temp file';
   binmode $in_fh;
   local $INPUT_RECORD_SEPARATOR = undef;
   my $out = <$in_fh>;
   close $in_fh or die;
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
      local $ENV{HTTP_ACCEPT_ENCODING} = q{};
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

# Older versions of this test used to set
#     local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip'
# and expected subshells to propagate that value.  That caused some
# smoke environments to fail, so I switched to passing that value as a
# cmdline argument.

# Turn off compression
ok(CGI::Compress::Gzip->useCompression(0), 'Turn off compression');

my $redir = 'http://www.foo.com/';

my $interp = "$^X -Iblib/arch -Iblib/lib";
if (defined $Devel::Cover::VERSION) {
   $interp .= ' -MDevel::Cover';
}
my $basecmd = "$interp t/testhelp";

# Get CGI header for comparison in basic case
my $compareheader = CGI->new(q{})->header();

my $eol = "\015\012"; ## no critic (ProhibitEscapedCharacters)

## no critic (RequireExtendedFormatting)

# no compression
{
   my $reason = 'X-non-gzip-reason: user agent does not want gzip' . $eol;
   my $out = `$basecmd simple "$compare"`;
   ok($out !~ s/Content-[Ee]ncoding: gzip\r?\n//ms &&
      $out !~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'CGI template (header encoding text)');
   is($out, $reason . $compareheader.$compare, 'CGI template (body test)');
}

# no body
{
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   my $zempty = Compress::Zlib::memGzip(q{});

   my $out = `$basecmd empty "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//ms ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'no body (header encoding text)');
   is($out, $compareheader.$zempty, 'no body (body test)');
}

# CGI and compression
{
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   my $out = `$basecmd simple "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//ms ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'Gzipped CGI template (header encoding text)');
   is($out, $compareheader.$zcompare, 'Gzipped CGI template (body test)');
}

# CGI with charset and compression
{
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   my $header = CGI->new(q{})->header(-Content_Type => 'text/html; charset=UTF-8');

   my $out = `$basecmd charset "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//ms ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'Gzipped CGI template with charset (header encoding text)');
   is($out, $header.$zcompare,
      'Gzipped CGI template with charset (body test)');
}

# CGI with arguments
{
   my $reason = 'X-non-gzip-reason: incompatible content-type foo/bar' . $eol;
   my $header = CGI->new(q{})->header(-Type => 'foo/bar');

   my $out = `$basecmd -DHTTP_ACCEPT_ENCODING=gzip type "$compare"`;
   ok($out !~ s/Content-[Ee]ncoding: gzip\r?\n//ms &&
      $out !~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'Un-Gzipped with -Type flag (argument processing text)');
   is($out, $reason . $header.$compare,
      'Un-Gzipped with -Type flag (body test)');
}

# CGI redirection and compression
{
   my $reason = 'X-non-gzip-reason: HTTP status not 200' . $eol;
   my $expected_header = CGI->new(q{})->redirect($redir);
   $expected_header =~ s/\s+\z/$eol$reason$eol/xms; # this is a more fragile regexp than expected...
   # A simple s/$eol$eol/.../xms did not work

   my $out = `$basecmd -DHTTP_ACCEPT_ENCODING=gzip redirect "$redir"`;
   ok($out !~ s/Content-[Ee]ncoding: gzip\r?\n//ms &&
      $out !~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'CGI redirect (header encoding text)');
   is($out, $expected_header, 'CGI redirect (body test)');
}

# unbuffered CGI
{
   my $reason = 'X-non-gzip-reason: user agent does not want gzip' . $eol;
   my $out = `$basecmd simple "$compare"`;
   ok($out !~ s/Content-[Ee]ncoding: gzip\r?\n//ms &&
      $out !~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'unbuffered CGI (header encoding text)');
   is($out, $reason . $compareheader.$compare, 'unbuffered CGI (body test)');
}

# Simulated mod_perl
{
   my $out = `$basecmd -DHTTP_ACCEPT_ENCODING=gzip mod_perl "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//ms ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'mod_perl simulation (header encoding text)');
   is($out, $compareheader.$zcompare, 'mod_perl simulation (body test)');
}

# Double print header
{
   my $out = `$basecmd -DHTTP_ACCEPT_ENCODING=gzip doublehead "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//ms ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'double header (header encoding text)');
   is($out, $compareheader.$zcompare, 'double header (body test)');
}

# redirected filehandle
SKIP: {
   my $out = `$basecmd -DHTTP_ACCEPT_ENCODING=gzip fh1 "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//ms ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'filehandle (header encoding text)');
   is($out, $compareheader.$zcompare, 'filehandle (body test)');
}

# redirected filehandle
SKIP: {
   skip('Explicit use of filehandles not yet supported', 2);

   my $out = `$basecmd -DHTTP_ACCEPT_ENCODING=gzip fh2 "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//ms ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'filehandle (header encoding text)');
   is($out, $compareheader.$zcompare, 'filehandle (body test)');
}

# redirected filehandle
SKIP: {
   skip('Explicit use of filehandles not yet supported', 2);

   my $out = `$basecmd -DHTTP_ACCEPT_ENCODING=gzip fh3 "$compare"`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//ms ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/ms,
      'filehandle (header encoding text)');
   is($out, $compareheader.$zcompare, 'filehandle (body test)');
}
