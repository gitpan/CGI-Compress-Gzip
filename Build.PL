use Module::Build;
Module::Build->new(
   module_name => 'CGI::Compress::Gzip',
   dist_author => 'Clotho Advanced Media, Inc. <cpan@clotho.com>',
   license => 'perl',
   requires => {
      'perl'             => '5.006',
      'CGI'              => '2.00',
      'IO::Zlib'         => '1.01',
   },
   build_requires => {
      'Test::More'       => '0.01',
      'File::Temp'       => 0,
   },
   add_to_cleanup => [ 'CGI-Compress-Gzip-*' ],
)->create_build_script;
