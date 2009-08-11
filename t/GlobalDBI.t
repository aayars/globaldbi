use strict;
use warnings;

my $basetests;
my $dbitests;
my $total;

use Test::More tests => 2;

my $reason;
my $tempdir;
my $dirname;

SKIP: {
  my $hasFileTempdir;

  eval {
    require File::Tempdir;

    $hasFileTempdir++;
  };

  if ( $hasFileTempdir ) {
    eval qq{
      use File::Tempdir;
    };
  } else {
    $reason = "File::Tempdir not installed";

    skip($reason, 2) if $reason;
  }

  if ( !$reason ) {
    eval {
      $tempdir = File::Tempdir->new;

      $dirname = $tempdir->name;
    };
  } else {
    $reason  = "Unusable filesystem (can't make tempdir)";
  }

  if ( !$reason && !$dirname ) {
    $reason = "Unable to get name for temp directory";
  }

  if ( !$reason ) {
    if ( !-d $dirname ) {
      $reason = "$dirname is not a directory (weird)";
    } elsif ( !-w $dirname ) {
      $reason = "$dirname is not writable (ponderous)";
    }

    skip($reason, 2) if $reason;
  }

  ###
  ### Class prototyping tests
  ###
  use_ok("GlobalDBI");

  my $hasSQLite;
  my $worked;

  $dirname ||= "";
  my $db = "$dirname/globaldbi-test";

  if ( !$reason ) {
    eval {
      require DBD::SQLite;

      $hasSQLite++;
    };
  }

  if ( !$reason && !$hasSQLite ) {
    $reason = "DBD::SQLite is not installed";
  }

  skip($reason, 1) if $reason;

  ok( createTable($db) );
}

sub createTable {
  my $db = shift;

  my $dsn = sprintf('DBI:SQLite:dbname=%s',$db);

  GlobalDBI->define(
    $db => [ $dsn, '', '', { RaiseError => 1 } ]
  );

  my $dbi = GlobalDBI->new(dbname => $db);

  my $dbh = $dbi->get_dbh();
  my $sth;

  eval {
    $sth = $dbh->prepare("create table testo ( foo VARCHAR(32) );")
      || die $dbh->errstr;
  };

  return undef if !$sth;

  $sth->execute || die $sth->errstr;

  return $sth->fetchall_arrayref() || die $sth->errstr;
}
