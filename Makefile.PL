use ExtUtils::MakeMaker;
WriteMakefile(
    'NAME'		=> 'CGI::Compress::Gzip',
    'VERSION_FROM'	=> 'Gzip.pm', # finds $VERSION
    'PREREQ_PM'		=> {
                            CGI => 2.00,
                            IO::Zlib => 1.01,
                           },
);
