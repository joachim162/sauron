package SauronAPI::Repository::Key;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(key_list);

use SauronAPI::Exception  ();
use SauronAPI::ListQuery  qw(compile_filters parse_sort sort_sql sort_echo list_metadata set_total);
use SauronAPI::Repository qw(dbq with_statement_timeout LIST_STATEMENT_TIMEOUT_MS);
use Sauron::BackEnd       ();

my %FILTER_SPEC = (
  name    => { kind => 'regex', col => 'name' },
  comment => { kind => 'regex', col => 'comment' },
);

my %SORT_COLUMN = (
  name    => 'name',
  comment => 'comment',
);

# Read-only TSIG key reference data (ADR 0011): selectors for the AML mode=2
# picker, mirroring the legacy CGI browse_keys view. Secrets are never read.
sub key_list {
  my ($server_id, %opts) = @_;

  my $page     = $opts{page}     // 1;
  my $per_page = $opts{per_page} // 50;

  my $sort = parse_sort($opts{sort}, \%SORT_COLUMN, default => 'name', tiebreak => 'id');
  my $filters = compile_filters($opts{params} // {}, \%FILTER_SPEC);
  my $meta = list_metadata($page, $per_page, sort_echo($sort), $filters->{echo});

  return ([], $meta) if $filters->{empty};

  my @bind = ($server_id);
  my $where = ' WHERE type=1 AND ref=? ';
  if ($filters->{where}) {
    $where .= " AND $filters->{where} ";
    push @bind, @{$filters->{bind}};
  }

  my ($rows, $count_rows);
  with_statement_timeout(LIST_STATEMENT_TIMEOUT_MS, sub {
    $rows = dbq(
      "SELECT id,name,algorithm,keysize,mode,comment,cdate,cuser,mdate,muser "
      . "FROM keys $where " . sort_sql($sort) . ' LIMIT ? OFFSET ?',
      @bind, $per_page, ($page - 1) * $per_page
    );
    $count_rows = dbq("SELECT COUNT(*) FROM keys $where", @bind);
  });
  set_total($meta, $count_rows->[0][0] // 0);

  my $keys = [ map { _build_summary($server_id, $_) } @$rows ];
  return ($keys, $meta);
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

sub _build_summary {
  my ($server_id, $row) = @_;
  my ($id, $name, $algorithm, $keysize, $mode, $comment, $cdate, $cuser, $mdate, $muser) = @$row;

  my $rec = {
    id        => $id + 0,
    server_id => $server_id,
    name      => $name,
    algorithm => defined $algorithm ? $algorithm + 0 : undef,
    keysize   => defined $keysize   ? $keysize   + 0 : undef,
    mode      => defined $mode      ? $mode      + 0 : undef,
    comment   => $comment,
    cdate     => $cdate,
    cuser     => $cuser,
    mdate     => $mdate,
    muser     => $muser,
  };
  $rec->{cdate} = defined $rec->{cdate} ? $rec->{cdate} + 0 : undef;
  $rec->{mdate} = defined $rec->{mdate} ? $rec->{mdate} + 0 : undef;
  Sauron::BackEnd::add_std_fields($rec);
  return $rec;
}

1;
