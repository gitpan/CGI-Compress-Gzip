#!/usr/bin/perl -w

use strict;
use warnings;
use Carp;
$SIG{__WARN__} = \&Carp::confess;
$SIG{__DIE__} = \&Carp::cluck;

BEGIN
{ 
   use Test::More tests => 12;
   use_ok("CGI::Compress::Gzip");
}

my $compare = "Hello World!";  # expected output
my $redir = "http://www.foo.com/";

# Get CGI header for comparison
my $compareheader = CGI->new("")->header();
my $compareheader2 = CGI->new("")->header(-Content_Type => "text/html; charset=UTF-8");
my $compareredir = CGI->new("")->redirect($redir);


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

my $basecmd = "$^X -Iblib/arch -Iblib/lib t/testhelp";
my $cmd = "$basecmd '$compare'";
my $cmd2 = "$basecmd charset '$compare'";
my $redircmd = "$basecmd redirect '$redir'";

# no compression
{
   my $out = `$cmd`;
   ok($out !~ s/Content-[Ee]ncoding: gzip\r?\n//si && 
      $out !~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi, 
      "CGI template (header encoding text)");
   is($out, $compareheader.$compare, "CGI template (body test)");
}

# CGI and compression
{
   local $ENV{HTTP_ACCEPT_ENCODING} = "gzip";

   my $out = `$cmd`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//si ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi,
      "Gzipped CGI template (header encoding text)");
   is($out, $compareheader.$zcompare, "Gzipped CGI template (body test)");
}

# CGI with charset and compression
{
   local $ENV{HTTP_ACCEPT_ENCODING} = "gzip";

   my $out = `$cmd2`;
   ok($out =~ s/Content-[Ee]ncoding: gzip\r?\n//si ||
      $out =~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi,
      "Gzipped CGI template with charset (header encoding text)");
   is($out, $compareheader2.$zcompare, 
      "Gzipped CGI template with charset (body test)");
}

# CGI redirection and compression
{
   local $ENV{HTTP_ACCEPT_ENCODING} = "gzip";

   my $out = `$redircmd`;
   ok($out !~ s/Content-[Ee]ncoding: gzip\r?\n//si && 
      $out !~ s/^(Content-[Ee]ncoding:\s*)gzip, /$1/mi, 
      "CGI redirect (header encoding text)");
   is($out, $compareredir, "CGI redirect (body test)");
}

unlink($testfile);
