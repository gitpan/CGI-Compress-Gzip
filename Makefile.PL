use ExtUtils::MakeMaker;
WriteMakefile(
              'NAME'		=> 'CGI::Compress::Gzip',
              'VERSION_FROM'	=> 'lib/CGI/Compress/Gzip.pm',
              'PREREQ_PM'		=> {
                 'CGI'          => '2.00',
                 'IO::Zlib'     => '1.01',
              },
              'PL_FILES'        => {},
              ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
               (ABSTRACT_FROM => 'lib/CGI/Compress/Gzip.pm',
                AUTHOR     => 'Clotho Advanced Media Inc. <cpan@clotho.com>') : ()),
);
