BEGIN
{ 
   use Test::More tests => 8;
   use_ok(CGI::Compress::Gzip);
}

use strict;
use warnings;

use Carp;
$SIG{__WARN__} = \&Carp::confess;
$SIG{__DIE__} = \&Carp::cluck;

my $compare = "Hello World!";  # expected output

# Get CGI header for comparison
my $compareheader = CGI->new("")->header();


eval "use IO::Zlib; use Compress::Zlib";
my $hasZlib = $@ ? 0 : 1;

# Have to use a temp file since Compress::Zlib doesn't like IO::String
my $testfile = "temp.test";

# Turn off compression
ok(CGI::Compress::Gzip->useCompression(0), "Turn off compression");

# First, some Zlib tests

my $zcompare = Compress::Zlib::memGzip($compare);
my $testbuf = $zcompare;
$testbuf = Compress::Zlib::memGunzip($testbuf);
is ($testbuf, $compare, "Compress::Zlib double-check");
{
   local *FILE1;
   open FILE1, ">$testfile" or die "Can't write a temp file";
   local *STDOUT = *FILE1;
   my $fh = IO::Zlib->new(\*FILE1, "wb");
   print $fh $compare;
   close $fh;
   close FILE1;

   open FILE1, "<$testfile" or die "Can't read temp file";
   my $out = join("", <FILE1>);
   close(FILE1);
   is($out, $zcompare, "IO::Zlib test");
}

my $cmd = "$^X -Iblib/arch -Iblib/lib testhelp '$compare'";

# no compression
{
   my $out = `$cmd`;
   ok($out !~ s/^Content-Encoding: gzip\n//s && $out !~ s/^(Content-Encoding:\s*)gzip, /$1/m, "CGI template (header encoding text)");
   is($out, $compareheader.$compare, "CGI template (body test)");
}

# CGI and compression
{
   local $ENV{HTTP_ACCEPT_ENCODING} = "gzip";

   my $out = `$cmd`;
   ok($out =~ s/^Content-Encoding: gzip\n//s || $out =~ s/^(Content-Encoding:\s*)gzip, /$1/m, "Gzipped CGI template (header encoding text)");
   is($out, $compareheader.$zcompare, "Gzipped CGI template (body test)");
}

unlink($testfile);
