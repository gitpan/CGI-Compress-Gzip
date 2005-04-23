use Module::Build;
Module::Build->new(
                   module_name => 'CGI::Compress::Gzip',
                   license => 'perl',
                   requires => {
                      'CGI'                      => '2.00',
                      'IO::Zlib'                 => '1.01',
                   },
                   build_requires => {
                      'Test::More'               => '0.01',
                   },
                   )->create_build_script;
