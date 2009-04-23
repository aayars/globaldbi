use ExtUtils::MakeMaker;

my $prereqs = {
  DBI    => 1.40,
  Fcntl  => 1.05,
};

WriteMakefile(
  ABSTRACT_FROM => 'lib/GlobalDBI.pm',
  VERSION_FROM  => 'lib/GlobalDBI.pm',
  NAME          => 'GlobalDBI',
  PREREQ_PM     => $prereqs,
);
