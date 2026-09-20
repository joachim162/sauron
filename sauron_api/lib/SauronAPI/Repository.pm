package SauronAPI::Repository;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(dbq check_rc with_statement_timeout validate_regex);

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

# Regex filters are evaluated by PostgreSQL (~*), not by Perl — the dialects
# differ (\K, \R, possessive quantifiers are Perl-only). Compile the pattern
# against the real engine and map SQLSTATE 2201B/2201C (invalid regular
# expression / invalid escape) to a 400 per ADR 0007.
sub validate_regex {
  my ($name, $pattern) = @_;
  my @probe;
  my $rc = Sauron::DB::db_query("SELECT '' ~* ?", \@probe, $pattern);
  if ($rc < 0) {
    my $err   = Sauron::DB::db_last_error_info();
    my $state = $err->{sqlstate} // '';
    my $msg   = $err->{message}  // '';
    SauronAPI::Exception->validation("Invalid regular expression for '$name'")
      if $state =~ /^2201[BC]$/ || $msg =~ /invalid regular expression/i;
    SauronAPI::Exception->persistence('Regex validation query failed');
  }
  return $pattern;
}

# Defensive statement timeout (ADR 0007): queries driven by user-supplied
# regex filters must not be able to pin database resources with an expensive
# pattern. The default is restored even when the guarded code throws.
sub with_statement_timeout {
  my ($ms, $code) = @_;
  return $code->() if Sauron::DB::db_exec("SET statement_timeout = ${ms}") < 0;
  my @ret;
  my $ok = eval { @ret = $code->(); 1 };
  my $err = $@;
  my $restored = Sauron::DB::db_exec('SET statement_timeout = DEFAULT') == 0;
  die $err unless $ok;
  SauronAPI::Exception->persistence('Failed to restore statement_timeout')
    unless $restored;
  return wantarray ? @ret : $ret[0];
}

1;
