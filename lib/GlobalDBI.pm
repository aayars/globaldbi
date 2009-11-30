#
# File: GlobalDBI.pm
#
# Copyright (c) 2009 TiVo Inc.
#
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Common Public License v1.0
# which accompanies this distribution, and is available at
# http://opensource.org/licenses/cpl1.0.txt
#
package GlobalDBI;

use strict;
use warnings;

our $VERSION = "0.22";

use base qw| Exporter |;

use DBI;
use Fcntl;

use vars qw(@EXPORT_OK %DBH);

our %CONNECTION = ();
our %App        = (

  #  MyApp => { # User => Password
  #    bob => 'jk32jk3jjkl',
  #  },
  #
  #  MyOtherApp => {
  #    sally => 'jk32jk3jjkl',
  #  },
);

@EXPORT_OK = qw(%App %CONNECTION);

our $DEBUG;
our $LOG_ERRORS;

our $LOG_DIR = '/tmp';

#=================================
# MySQL Database Setups Go Here
#=================================

# %CONNECTION = (
#   MyApp => [
#     'DBI:mysql:MyApp:localhost',
#     'monitor',
#     _getDBPasswd( App => 'MyApp', username => 'bob' ),
#     {
#       RaiseError => 1,
#       PrintError => 1, #print to STDERR
#     },
#   ],
# );

sub define {
  my $class   = shift;
  my %sources = @_;

  for my $source ( keys %sources ) {
    $CONNECTION{$source} = $sources{$source};
  }
}

sub new {
  my $class = shift;
  my $self  = {};
  bless $self, $class;

  my %args = @_;

  $self->_init(%args);
  $self->{dbName} ||= $args{dbname};    # Legacy usage
  $self->{dbName} ||= $args{dbName};
  $self->{dbh} = $self->_get_db_connection();

  if ( $self->errstr ) {
    warn $self->errstr;
    return undef;
  }

  $self->{_statements} = {};

  return $self;
}

# Stub incase subclass doesnt have it.
sub _init {
}

sub _getDBPasswd {
  my %ARGS = (@_);

  my $passwd;

  do {
    no warnings "once";

    $passwd = $GlobalDBI::Credentials::App{ $ARGS{App} }->{ $ARGS{username} };
  };

  return $passwd;
}

# explicitly drop this connection
sub db_disconnect {
  my $self = shift;

  return undef unless ( defined $DBH{$$}->{ $self->{dbName} } );
  $DBH{$$}->{ $self->{dbName} }->disconnect;
  delete $DBH{$$}->{ $self->{dbName} };
}

# get the db handle for direct DBI method calls
sub get_dbh {
  my $self = shift;
  return $self->{dbh};
}

#=======================================================
# SELECT METHODS
#=======================================================

sub get_column_names {
  my ( $self, $tableName ) = @_;

  return undef unless $tableName;
  my $sth = $self->select_data(qq|LISTFIELDS $tableName|);

  return undef unless $sth;
  return \@{ $sth->{NAME} };
}

sub select_scalar {
  my $self = shift;
  my $sth  = $self->select_data(@_);
  return undef unless $sth;

  return $sth->fetchrow_arrayref()->[0];
}

# sql, [bind_params]
sub select_list {
  my $self = shift;
  my $sth  = $self->select_data(@_);
  return undef unless $sth;

  #return $sth->fetchall_arrayref([0]);
  my @list = ();
  map { push @list, $_->[0] } @{ $sth->fetchall_arrayref( [0] ) };
  return \@list;
}

sub select_record {
  my ( $self, $params ) = @_;
  $params->{key} ||= 'id';

  my $sth = $self->select_data(
    qq|SELECT * FROM $params->{table} WHERE $params->{key}=? LIMIT 1|,
    $params->{value} );
  return undef unless $sth;

  return $sth->fetchrow_hashref();
}

sub select_record_multi {
  my ( $self, $params ) = @_;
  $params->{key} ||= 'id';

  my $keyList = '?,' x scalar @{ $params->{value} };
  $keyList =~ s/,$//;
  my $sql =
    qq|SELECT * FROM $params->{table} WHERE $params->{key} in($keyList)|;

  return $self->select_hash_list( $sql, $params->{value} );
}

sub select_hash_list {
  my $self = shift;
  my $sth  = $self->select_data(@_);

  return undef unless $sth;

  my $aref = $sth->fetchall_arrayref( {} );
  $self->_set_err_str( 'incomplete fetch - ' . $sth->errstr ) if $sth->err;
  return $aref;
}

# { sql, [bind_params], key }
sub select_hash_by_key {
  my ( $self, $params ) = @_;
  my $key = $params->{key} || 'id';

  if (  $params->{sql} !~ m/select *.*from/si
    and $params->{sql} !~ m/\b$key\b.*(FROM|from)/s )
  {
    $self->_set_err_str(
      'select_hash_by_key: select does not contain key: ' . $key );
    $LOG_ERRORS && $self->_log_error('R');
    return undef;
  }

  my $sth = $self->select_data( $params->{sql}, $params->{bind_params} );
  return undef unless $sth;

  my $href = $sth->fetchall_hashref($key);
  $self->_set_err_str( 'incomplete fetch - ' . $sth->errstr ) if $sth->err;
  return $href;
}

# select id, name - will result in href->{id} = name
# { sql, [bind_params] }
sub select_hash_map {
  my ( $self, $params ) = @_;
  my $sth = $self->select_data( $params->{sql}, $params->{bind_params} );
  return undef unless $sth;

  my %h = ();
  while ( my $aref = $sth->fetchrow_arrayref() ) {
    $h{ $aref->[0] } = $aref->[1];
  }
  return \%h;
}

sub select_record_hashref {
  my ( $self, $params ) = @_;

  my $sth = $self->select_data(
    qq|SELECT * FROM $params->{table} WHERE $params->{key}=?|,
    $params->{value} );

  my %results;
  foreach my $row ( $sth->fetchrow_hashref() ) {
    foreach my $key ( keys %$row ) {
      $results{$key} = $row->{$key};
    }
  }

  return \%results;
}

# sql, [bind_params]
sub select_data {
  my $self = shift;
  return $self->_do_sql( 'R', @_ );
}

#=======================================================
# UPDATE METHODS
#=======================================================

# table, {data}
sub insert_record {
  my ( $self, $table, $data ) = @_;

  my ( @fields, @values, @placeHolders );

  foreach my $field ( keys %$data ) {
    my $value = length( $data->{$field} ) ? $data->{$field} : '';
    if ( $value =~ m/^(curdate\(\)|now\(\))$/i ) {
      push( @placeHolders, $value );
    } else {
      push( @placeHolders, '?' );
      push( @values,       $value );
    }
    push( @fields, $field );
  }
  my $sql = "INSERT INTO $table (" . join( ',', @fields ) . ') VALUES (';
  $sql .= join( ',', @placeHolders ) . ')';

  return $self->write_data( $sql, \@values );
}

# { table, key, value, {data} }
sub update_record {
  my ( $self, $params ) = @_;

  my ( $set, $qArgs ) = $self->_build_update_sql( $params->{data} );
  my $where = $params->{keyName} || 'id';

  if ( ref( $params->{keyValue} ) eq 'ARRAY' ) {
    my @values = @{ $params->{keyValue} };
    $where .= $self->_build_in_list( scalar @values );
    push( @$qArgs, @values );
  } else {
    $where .= '=? LIMIT 1';
    push( @$qArgs, $params->{keyValue} );
  }

  my $statement = "UPDATE $params->{table} SET $set WHERE $where";
  return $self->write_data( $statement, $qArgs );
}

# table, key, value
sub delete_record {
  my ( $self, $params ) = @_;
  my $limit = ( $params->{limit} ) ? "LIMIT $params->{limit}" : '';

  my $qArgs = [];
  my $condition = $params->{key} || 'id';
  if ( ref( $params->{value} ) eq 'ARRAY' ) {
    my @values = @{ $params->{value} };
    $condition .= $self->_build_in_list( scalar @values );
    push( @$qArgs, @values );
  } else {
    $condition .= "=? $limit";
    push( @$qArgs, $params->{value} );
  }

  return $self->write_data( qq|DELETE FROM $params->{table} WHERE $condition|,
    $qArgs );
}

# sql, [bind_params]
sub write_data {
  my ( $self, $sql ) = @_;

  my $sth = $self->_do_sql( 'W', $sql, pop );

  return undef unless $sth;
  return $sql =~ m/^\W*insert\s/i ? $sth->{mysql_insertid} : $sth->rows;
}

sub get_error_string {
  my $self = shift;
  return $self->{_lastErrorStr} || $DBI::errstr;
}

sub errstr {
  return get_error_string(@_);
}

#=======================================================
# PRIVATE METHODS
#=======================================================

sub _get_db_connection {
  my $self = shift;

  $DBH{$$} ||= {};

  unless ( defined $CONNECTION{ $self->{dbName} } ) {
    $self->_set_err_str( 'unknown db: ' . $self->{dbName} );
    $LOG_ERRORS && $self->_log_error('W');
    return undef;
  }

  return $DBH{$$}->{ $self->{dbName} }
    if ( defined $DBH{$$}->{ $self->{dbName} } );

  $DEBUG && print STDERR "DBI connect: $self->{dbName}\n";

  #print STDERR join(',',@{$CONNECTION{$self->{dbName}}}) ."\n" if $DEBUG;

  my $retry = 0;
  my $dbh;
  while ( $retry++ <= 5 and !$dbh ) {
    eval {
      $dbh = DBI->connect( @{ $CONNECTION{ $self->{dbName} } } )
        || die $DBI::errstr;
    };
  }
  unless ($dbh) {
    $self->_set_err_str($@);
    $LOG_ERRORS && $self->_log_error('W');
    return undef;
  }

  $DBH{$$}->{ $self->{dbName} } = $dbh;
  return $dbh;
}

# prepare, execute, and return sth
sub _do_sql {
  my ( $self, $rw, $sql, $params ) = @_;

  return undef unless $sql;
  return undef
    if ( $rw eq 'R' and $sql !~ /^\W*(select|listfields|describe)/i );
  return undef if ( $rw eq 'W' and $sql !~ /^\W*(update|insert|delete)/i );
  $params = [$params] unless ( ref($params) eq 'ARRAY' || !$params );

  $self->{_lastErrorStr} = '';
  $DEBUG && print STDERR "sql: $sql\n";

  unless ( ref $self->{dbh} ) {
    my $values = $params ? join( ':-:', @$params ) : '';
    $self->_set_err_str("not connected - Sql: $sql :-: $values\n");
    $LOG_ERRORS && $self->_log_error($rw);
    return undef;
  }

  my $sth;
  if ( $self->{_statements}{$sql} ) {    # check for cached statements
    $DEBUG && print STDERR "found cached statement: $sql\n";
    $sth = $self->{_statements}{$sql};
  } else {
    unless ( $self->{_statements}{$sql} = $sth = $self->{dbh}->prepare($sql) ) {
      $self->_set_err_str(
        "failed sth obj creation: $DBI::errstr - Sql: $sql\n");
      $LOG_ERRORS && $self->_log_error($rw);
      return undef;
    }
  }

  unless ( $sth = $self->{dbh}->prepare($sql) ) {
    $self->_set_err_str("prepare failed: $DBI::errstr - Sql: $sql\n");
    $LOG_ERRORS && $self->_log_error($rw);
    return undef;
  }

  $DEBUG
    && ref($params)
    && print STDERR 'params: ' . join( ',', @{$params} ) . "\n";
  unless ( $sth->execute(@$params) ) {
    my $errs = $DBI::errstr || '';
    my $vals = ref($params) ? join( ',', @$params ) : 'n/a';
    $self->_set_err_str("execute error: $sql with: $vals - $errs");
    $LOG_ERRORS && $self->_log_error($rw);
    $sth->finish();
    return undef;
  }
  return $sth;
}

sub _build_update_sql {
  my ( $self, $dataRef ) = @_;
  my ( @fields, @values, @set );

  foreach my $field ( keys %$dataRef ) {
    my $value = length( $dataRef->{$field} ) ? $dataRef->{$field} : '';
    if ( $value =~ m/curdate\(\)|now\(\)/i ) {
      push( @set, join( '=', $field, $value ) );
    } else {
      push( @set,    $field . '=?' );
      push( @values, $value );
    }
  }

  return ( join( ',', @set ), \@values );
}

sub _build_in_list {
  my $self = shift;
  my $length = shift || 0;

  my $in = ' in(';
  $in .= '?,' while ( $length-- );
  chop $in;
  $in .= ')';

  return $in;
}

sub _set_err_str {
  my $self = shift;
  $self->{_errorCount}++;
  $self->{_lastErrorStr} = shift || $DBI::errstr;
}

sub _log_error {
  my ( $self, $type, $error ) = @_;

  $error ||= $self->{_lastErrorStr};
  $error =~ s/\n/ /g;

  my $message = join( ' ', time, $0, $error );

  my $name = $self->{dbName};
  $name =~ s/.*\///;    # SQLite uses full paths

  my $sqlLog = join( '/', $LOG_DIR, $name );
  $sqlLog .= $type eq 'W' ? '_sqlErr_write' : '_sqlErr_read';

  local (*LOG);
  open( LOG, ">>$sqlLog" )
    or die "can't log errors to $sqlLog: $!";

  flock( LOG, &Fcntl::LOCK_EX );
  select( ( select(LOG), $| = 1 )[0] );
  seek( LOG, 0, 2 );
  print LOG $message;
  print LOG "\n";
  flock( LOG, &Fcntl::LOCK_UN );

  close(LOG);
}

# drop all open connections
# will need to change if used under mod_perl
END {
  foreach my $dbn ( keys %{ $DBH{$$} } ) {
    print STDERR "DBI disconnect: $dbn\n" if $DEBUG;
    $DBH{$$}->{$dbn}->disconnect;
  }
}

1;

__END__

=head1 NAME

GlobalDBI - Simple DBI wrapper with support for multiple connections

=cut

=head1 SYNOPSIS

  use GlobalDBI;

  #
  # Define a new data source:
  #
  my $dsn = 'DBI:SQLite:dbname=example';

  GlobalDBI->define(
    "YourApp" => [ $dsn, '', '', { RaiseError => 1 } ],
  };

  #
  # Connect to a named data source:
  #
  my $dbi = GlobalDBI->new(dbName => "YourApp") || die $@;

=head1 DESCRIPTION
                                                                                
GlobalDBI is a helper/wrapper for L<DBI>.  It provides error logging,
methods to perform common db functions, and support for connections to
multiple databases.  Since it uses DBI, you can still use native DBI
method calls using the db-handle returned from C<get_dbh()>.

Errors are logged to the files defined in C<_log_error> - one for read,
one for write type functions

Database connection info (type, host, user, paswd, attributes) are defined
in the I<CONNECTION> hash located just before the C<_get_dbConnection>
method.  Since all errors are logged, the I<PrintError> attribute can
be set to 0 unless you still want errors printed to STDERR.

Most all methods return undef on error so you should check the value
before using it.
                                                                                
=head2 Example

  my $myDBI = GlobalDBI->new(dbName => 'my_db');
  my $sth = $myDBI->select_data('select * from JUNK where a=? and b=?',
    ['joe', 'bob']);
  foreach my $row($sth->fetchrow_hashref())
  {
    print "a = $row->{a} b = $row->{b} c = $row->{c}\n";
  }

GlobalDBI internally calls DBI's prepare and execute methods and logs any errors
according to the settings in _log_error.  Errors will cause undef to be returned
so you should check the value before using it.
                                                                                
=head1 METHODS

=over 4

=item * C<db_disconnect>

explicitly drop this connection now

=item * C<get_dbh>

returns the db handle for the current db so you can make direct DBI calls

  my $dbh = $db->get_dbh();
  $dbh->prepare... etc

=item * C<get_column_names>

returns the column names for the supplied table

  my $columns = $db->get_column_names('my_table');
  print join(',', @$columns);

=item * C<select_record>

meant for selecting 1 unique record using a primary key

pass an array ref for the I<value> key to select multiple records by primary key

  my $record = $db->select_record({
      table => 'my_table',
      key => 'my_table_id',
      value => 1000,
  });

=item * C<select_hash_list>

pass your custom sql (select) and bind param list

returns a reference to a list of hashrefs

  my $list = $db->select_hash_list('select * from my_table where id > ?',$minID);
  foreach my $hRef(@$list) {
      print $hRef->{fieldNameA};
  }

=item * C<select_hash_by_key>

pass your custom sql (select), bind param list, and a column name to
use as the hash key to point at each row of data returned.  Make sure
the key will be unique to avoid overwriting.  Also make sure the key is
in the select list (unless doing a 'select *')

  my $hashRef = $db->select_hash_by_key({
      sql => 'select id, name, age, sex from user where active=?',
      args => 'YES',
      key => 'id',
  });

  print $hashRef->{1001}{name};
  print $hashRef->{1002}{age};

=item * C<select_data>

pass your custom sql (select) and bind param list then use the returned
DBI::st handle to call fetchrow_hashref, fetchrow_arrayref, etc

  my $sth = $db->select_data('select * from my_table where id > ?', $value);
  my $rows = $sth->fetchall_arrayref();
  ...

=item * C<insert_record>

pass the table name and a hashRef of data where the keys are the field names

returns the new id (assuming the table had an auto-incrementing id)

  my $id = $db->insert_record('my_table', $dataRef);

=item * C<update_record>

meant for updating a unique record using a primary key

pass an array ref for the I<value> key to update multiple records by primary key

returns the number of rows updated

  my $rowsAffected = $db->update_record({
      table    => 'my_table',
      data     => $dataRef, # hashref where keys are the field names in test_table
      keyName  => 'id',
      keyValue => [1,2,3,...] or '1',
  });

=item * C<delete_record>

meant for deleting a unique record using a primary key

pass an array ref for the I<value> key to update multiple records by primary key

returns the number of rows deleted

Specifying a LIMIT is optional

  my $rowsAffected = $db->delete_record({
      table => 'test_table',
      key => 'my_table_id',
      value => $id,
      limit => 1,
  });

=item * C<write_data>

pass your custom sql (update, insert, delete) and param list

returns affected row count or insertid

  my $deleted_rows = $db->write_data(
    'delete from my_table where date_created > ? and userid like \'%test\'',
    $testDate
  );

=item * C<errstr>, C<get_error_string>

returns the latest error text set as a result of the last action

  my $insertID = $db->write_data('delete from non_existent_table');
  unless ($insertID > 0) {
    print STDERR $db->errstr();
  }

=cut


=item * C<insert_record>

pass the table name and a hashRef of data where the keys are the field names

returns the new id (assuming the table had an auto-incrementing id)

  my $id = $db->insert_record('my_table', $dataRef);

=item * C<update_record>

meant for updating a unique record using a primary key

pass an array ref for the I<value> key to update multiple records by primary key

returns the number of rows updated

  my $rowsAffected = $db->update_record({
      table => 'my_table',
      data => $dataRef, # hashref where keys are the field names in test_table
      value => $id,
  });

=item * C<delete_record>

meant for deleting a unique record using a primary key

pass an array ref for the I<value> key to update multiple records by primary key

returns the number of rows deleted

  my $rowsAffected = $db->delete_record({
      table => 'test_table',
      key => 'my_table_id',
      value => $id,
  });

=item * C<write_data>

pass your custom sql (update, insert, delete) and param list

returns affected row count or insertid

  my $deleted_rows = $db->write_data(
    'delete from my_table where date_created > ? and userid like \'%test\'',
    $testDate
  );

=item * C<errstr>, C<get_error_string>

returns the latest error text set as a result of the last action

  my $insertID = $db->write_data('delete from non_existent_table');
  unless ($insertID > 0) {
    print STDERR $db->errstr();
  }

=back

=head1 REVISION

This document is for version 0.22 of GlobalDBI.

=head1 AUTHOR

Ryan Rose, Joe Spinney, Alex Ayars <pause@nodekit.org>

=head1 COPYRIGHT

  File: GlobalDBI.pm
 
  Copyright (c) 2009 TiVo Inc.
 
  All rights reserved. This program and the accompanying materials
  are made available under the terms of the Common Public License v1.0
  which accompanies this distribution, and is available at
  http://opensource.org/licenses/cpl1.0.txt

=cut
