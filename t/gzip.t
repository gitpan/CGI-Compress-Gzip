#!/usr/bin/perl -w

use strict;
use warnings;
use File::Temp qw(tempfile);
use IO::Zlib;
use Compress::Zlib;
use English qw(-no_match_vars);

BEGIN
{ 
   use Test::More tests => 59;
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
   local *STDOUT = *FILE1;
   my $fh = IO::Zlib->new(\*FILE1, 'wb');
   print $fh $compare;
   close $fh;
   close FILE1;

   open FILE1, '<', $testfile or die 'Cannot read temp file';
   my $out = join(q{}, <FILE1>);
   close(FILE1);
   is($out, $zcompare, 'IO::Zlib test');
}

## Header tests

{
   my $dummy = CGI::Compress::Gzip->new();
   my @headers;

   ok(!$dummy->isCompressibleType(), "compressible types");
   ok($dummy->isCompressibleType("text/html"), "compressible types");
   ok($dummy->isCompressibleType("text/plain"), "compressible types");
   ok(!$dummy->isCompressibleType("image/jpg"), "compressible types");
   ok(!$dummy->isCompressibleType("application/octet-stream"), "compressible types");
 
   {
      local $ENV{HTTP_ACCEPT_ENCODING} = '';
      @headers = ();
      is_deeply([$dummy->_canCompress(\@headers), \@headers],
                [0, []],
                "header test - env");

      local $CGI::Compress::Gzip::global_give_reason = 1;
      @headers = ();
      is($dummy->_canCompress(\@headers), 0, "header test - reason");
      is(scalar @headers, 2, "header test - reason");
      is($headers[0], "-X_non_gzip_reason", "header test - reason");
   }

   {
      local $ENV{HTTP_ACCEPT_ENCODING} = 'bzip2';
      @headers = ();
      is_deeply([$dummy->_canCompress(\@headers), \@headers],
                [0, []],
                "header test - env");
   }

   # For the rest of the tests, pretend browser told us to turn on gzip
   local $ENV{HTTP_ACCEPT_ENCODING} = 'gzip';

   @headers = ();
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["-Content_Encoding", "gzip"]],
             "header test - env");

   {
      local $CGI::Compress::Gzip::global_give_reason = 1;
      @headers = ();
      is_deeply([$dummy->_canCompress(\@headers), \@headers],
                [1, ["-Content_Encoding", "gzip"]],
                "header test - reason");
   }

   # Turn off compression
   CGI::Compress::Gzip->useCompression(0);
   @headers = ();
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [0, []],
             "header test - override");
   CGI::Compress::Gzip->useCompression(1);

   # Turn off compression
   $dummy->useCompression(0);
   @headers = ();
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [0, []],
             "header test - override");
   $dummy->useCompression(1);

   {
      local $OUTPUT_AUTOFLUSH = 1;
      @headers = ();
      is_deeply([$dummy->_canCompress(\@headers), \@headers],
                [0, []],
                "header test - autoflush");
   }

   @headers = ("text/plain");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["-Content_Type", "text/plain", "-Content_Encoding", "gzip"]],
             "header test - type");

   @headers = ("-Content_Type", "text/plain");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["-Content_Type", "text/plain", "-Content_Encoding", "gzip"]],
             "header test - type");

   @headers = ("Content_Type", "text/plain");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["Content_Type", "text/plain", "-Content_Encoding", "gzip"]],
             "header test - type");

   @headers = ("-type", "text/plain");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["-type", "text/plain", "-Content_Encoding", "gzip"]],
             "header test - type");

   @headers = ("Content_Type: text/plain");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["Content_Type: text/plain", "-Content_Encoding", "gzip"]],
             "header test - type");

   @headers = ("Content_Type: image/gif");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [0, ["Content_Type: image/gif"]],
             "header test - type");

   @headers = ("-Content_Encoding", "foo");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["-Content_Encoding", "gzip, foo"]],
             "header test - encoding");

   @headers = ("-Content_Encoding", "gzip");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [0, ["-Content_Encoding", "gzip"]],
             "header test - encoding");

   @headers = ("Content-Encoding: foo");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["Content-Encoding: gzip, foo"]],
             "header test - encoding");

   @headers = ("-Status", "200");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["-Status", "200", "-Content_Encoding", "gzip"]],
             "header test - status");

   @headers = ("Status: 200");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["Status: 200", "-Content_Encoding", "gzip"]],
             "header test - status");

   @headers = ("Status: 200 OK");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["Status: 200 OK", "-Content_Encoding", "gzip"]],
             "header test - status");

   @headers = ("Status: 500");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [0, ["Status: 500"]],
             "header test - status");

   @headers = ("-Status", "junk");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [0, ["-Status", "junk"]],
             "header test - status");

   @headers = ("Status: junk");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [0, ["Status: junk"]],
             "header test - status");

   @headers = ("-Irrelevent", "1");
   is_deeply([$dummy->_canCompress(\@headers), \@headers],
             [1, ["-Irrelevent", "1", "-Content_Encoding", "gzip"]],
             "header test - other");
}

## Tests that are as real-life as we can manage

# Turn off compression
ok(CGI::Compress::Gzip->useCompression(0), 'Turn off compression');

my $redir = 'http://www.foo.com/';

my $interp = "$^X -Iblib/arch -Iblib/lib";
$interp .= " -MDevel::Cover" if (defined $Devel::Cover::VERSION);
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

   my $zempty = Compress::Zlib::memGzip("");

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
