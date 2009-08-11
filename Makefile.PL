use ExtUtils::MakeMaker;

my $prereqs = {
  DBI           => 1.40,
  File::Tempdir => 0.02,
};

WriteMakefile(
  ABSTRACT_FROM => 'lib/GlobalDBI.pm',
  VERSION_FROM  => 'lib/GlobalDBI.pm',
  NAME          => 'GlobalDBI',
  PREREQ_PM     => $prereqs,
  LICENSE       => 'open_source',
  AUTHOR        => 'Ryan Rose, Joe Spinney, Alex Ayars <pause@nodekit.org>',
);
