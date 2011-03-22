use strict;
use warnings;
package Moonpig::Storage;

use Class::Rebless 0.009;
use DBI;
use File::Spec;

use Moonpig::Logger '$Logger';

use Moonpig::Types qw(Ledger);
use Moonpig::Util qw(class class_roles);
use Scalar::Util qw(blessed);
use Storable qw(nfreeze thaw);

use namespace::autoclean;

sub _root {
  return($ENV{MOONPIG_STORAGE_ROOT} || die('no storage root'));
}

sub _dbh {
  my ($self, $guid) = @_;

  my $db_file = File::Spec->catfile(
    $self->_root,
    "moonpig.sqlite",
  );

  my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$db_file", undef, undef,
    { RaiseError => 1 },
  );

  return $dbh;
}

sub store_ledger {
  my ($self, $ledger) = @_;

  Ledger->assert_valid($ledger);

  $Logger->log_debug([
    'storing %s under guid %s',
    $ledger->ident,
    $ledger->guid,
  ]);

  my $dbh = $self->_dbh;

  $dbh->begin_work;

  $dbh->do(q{
    CREATE TABLE IF NOT EXISTS stuff (
      guid TEXT NOT NULL,
      name TEXT NOT NULL,
      blob BLOB NOT NULL,
      PRIMARY KEY (guid, name)
    );
  });

  $dbh->do(q{
    CREATE TABLE IF NOT EXISTS xid_ledgers (
      xid TEXT PRIMARY KEY,
      ledger_guid TEXT NOT NULL
    );
  });

  $dbh->do(
    q{
      INSERT OR REPLACE INTO stuff
      (guid, name, blob)
      VALUES (?, 'class_roles', ?)
    },
    undef,
    $ledger->guid,
    nfreeze( class_roles ),
  );

  $dbh->do(
    q{
      INSERT OR REPLACE INTO stuff
      (guid, name, blob)
      VALUES (?, 'ledger', ?)
    },
    undef,
    $ledger->guid,
    nfreeze( $ledger ),
  );

  $dbh->do(
    q{DELETE FROM xid_ledgers WHERE ledger_guid = ?},
    undef,
    $ledger->guid,
  );

  my $xid_sth = $dbh->prepare(
    q{INSERT INTO xid_ledgers (xid, ledger_guid) VALUES (?,?)},
  );

  for my $xid ($ledger->xids_handled) {
    $Logger->log_debug([
      'registering ledger %s for xid %s',
      $ledger->ident,
      $xid,
    ]);
    $xid_sth->execute($xid, $ledger->guid);
  }

  $dbh->commit;
}

sub known_guids {
  my ($self) = @_;
  my $dbh = $self->_dbh;

  my $guids = $dbh->selectcol_arrayref(q{SELECT DISTINCT guid FROM stuff});
  return @$guids;
}

sub retrieve_ledger_for_xid {
  my ($self, $xid) = @_;

  my $dbh = $self->_dbh;

  my ($ledger_guid) = $dbh->selectrow_array(
    q{SELECT ledger_guid FROM xid_ledgers WHERE xid = ?},
    undef,
    $xid,
  );

  $Logger->log_debug([ 'retrieved guid %s for xid %s', $ledger_guid, $xid ]);

  return $self->retrieve_ledger_for_guid($ledger_guid);
}

sub retrieve_ledger_for_guid {
  my ($self, $guid) = @_;

  $Logger->log_debug([ 'retrieving ledger under guid %s', $guid ]);

  my $dbh = $self->_dbh;
  my ($class_blob) = $dbh->selectrow_array(
    q{SELECT blob FROM stuff WHERE guid = ? AND name = 'class_roles'},
    undef,
    $guid,
  );

  my ($ledger_blob) = $dbh->selectrow_array(
    q{SELECT blob FROM stuff WHERE guid = ? AND name = 'ledger'},
    undef,
    $guid,
  );

  require Moonpig::DateTime; # has a STORABLE_freeze -- rjbs, 2011-03-18

  my $class_map = thaw($class_blob);
  my $ledger    = thaw($ledger_blob);

  my %class_for;
  for my $old_class (keys %$class_map) {
    my $new_class = class(@{ $class_map->{ $old_class } });
    next if $new_class eq $old_class;

    $class_for{ $old_class } = $new_class;
  }

  Class::Rebless->custom($ledger, '...', {
    editor => sub {
      my ($obj) = @_;
      my $class = blessed $obj;
      return unless exists $class_for{ $class };
      bless $obj, $class_for{ $class };
    },
  });

  return $ledger;
}

1;
