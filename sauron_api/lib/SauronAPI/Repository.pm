package SauronAPI::Repository;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(dbq check_rc);

use Sauron::DB           ();
use SauronAPI::Exception ();

# Shared plumbing for SauronAPI::Repository::<Resource> modules
# (data-layer helpers with no HTTP context — never touch $c here).

# Sauron::DB::db_query returns -1 on error instead of dying; a failed query
# must not silently become an empty result set. Use for all own-SQL reads.
sub dbq {
  my ($sql, @bind) = @_;
  my @rows;
  my $rc = Sauron::DB::db_query($sql, \@rows, @bind);
  if ($rc < 0) {
    SauronAPI::Exception->persistence("Database query failed");
  }
  return \@rows;
}

# Map a Sauron::BackEnd return code (0 = ok) to an exception on failure.
sub check_rc {
  my ($rc, $err) = @_;
  return if $rc == 0;
  SauronAPI::Exception->persistence($err);
}

1;
