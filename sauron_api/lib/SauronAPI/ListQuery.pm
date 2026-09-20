package SauronAPI::ListQuery;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  compile_filters parse_sort sort_sql sort_echo list_metadata set_total
);

use Time::Local qw(timegm);
use Sauron::Util qw(is_cidr is_ip);
use SauronAPI::Exception ();
use SauronAPI::Repository qw(validate_regex);

# Shared list-query compiler (ADR 0003 envelope, ADR 0007 filter semantics).
# It compiles filters/sort to SQL fragments + bind values; repositories
# execute. It is policy-free by construction: nothing here reads alevel,
# superuser, stash or $c — authorization arrives as caller-derived
# constraints composed into the repository's own WHERE. Values are always
# bound; identifiers come only from hardcoded spec entries. Custom callbacks
# are trusted application code and receive only the raw value; context
# reaches them through closures, never a context parameter.

my @DEFAULT_IGNORE = qw(page per_page sort);

sub compile_filters {
  my ($params, $spec, %opts) = @_;

  my %ignore = map { $_ => 1 } (@DEFAULT_IGNORE, @{$opts{ignore} // []});

  my %param_to_entry;
  for my $name (keys %$spec) {
    my $entry = $spec->{$name};
    if (($entry->{kind} // '') eq 'date_range') {
      for my $bound (qw(from to)) {
        my $pname = "${name}_${bound}";
        $param_to_entry{$pname} = { %$entry, bound => $bound };
      }
    } else {
      $param_to_entry{$name} = { %$entry };
    }
  }

  my @where;
  my @bind;
  my @echo;
  my $empty = 0;

  for my $name (sort keys %$params) {
    next if $ignore{$name};
    my $value = $params->{$name};
    $value = $value->[-1] if ref $value eq 'ARRAY';
    next unless defined $value && length $value;
    my $entry = $param_to_entry{$name}
      or SauronAPI::Exception->validation("Unknown filter '$name'");

    my ($clauses, $binds, $echo, $entry_empty) = _compile_entry($name, $value, $entry);
    push @where, @$clauses if @$clauses;
    push @bind,  @$binds   if @$binds;
    push @echo,  @$echo    if $echo;
    $empty ||= $entry_empty;
  }

  return {
    where => join(' AND ', @where),
    bind  => \@bind,
    echo  => \@echo,
    empty => $empty ? 1 : 0,
  };
}

my %KINDS = (
  regex      => \&_kind_regex,
  regex_any  => \&_kind_regex_any,
  enum       => \&_kind_enum,
  bool       => \&_kind_bool,
  int        => \&_kind_int,
  cidr       => \&_kind_cidr,
  date_range => \&_kind_date_range,
  custom     => \&_kind_custom,
);

sub _compile_entry {
  my ($name, $value, $entry) = @_;
  my $kind = $entry->{kind} // '';
  my $code = $KINDS{$kind}
    or die "Unknown filter kind '$kind' for '$name'";
  return $code->($name, $value, $entry);
}

sub _echo {
  my ($name, $value) = @_;
  return [{ name => $name, value => $value }];
}

sub _kind_regex {
  my ($name, $value, $entry) = @_;
  my $p = validate_regex($name, $value);
  $p = $entry->{transform}->($p) if $entry->{transform};
  return ([$entry->{col} . ' ~* ?'], [$p], _echo($name, $value), 0);
}

sub _kind_regex_any {
  my ($name, $value, $entry) = @_;
  my $p = validate_regex($name, $value);
  my @cols = @{$entry->{cols}};
  return (['(' . join(' OR ', map { "$_ ~* ?" } @cols) . ')'], [($p) x @cols],
    _echo($name, $value), 0);
}

sub _kind_enum {
  my ($name, $value, $entry) = @_;
  my @values = @{$entry->{values}};
  SauronAPI::Exception->validation(
    "Invalid value '$value' for '$name' (allowed: " . join(', ', @values) . ')'
  ) unless grep { $_ eq $value } @values;
  return ([$entry->{col} . ' = ?'], [$value], _echo($name, $value), 0);
}

sub _kind_bool {
  my ($name, $value, $entry) = @_;
  my $b = lc $value;
  SauronAPI::Exception->validation("Invalid boolean '$value' for '$name' (true or false)")
    unless $b =~ /^(?:true|false|1|0)$/;
  my $bound = ($b eq 'true' || $b eq '1') ? 't' : 'f';
  return ([$entry->{col} . ' = ?'], [$bound], _echo($name, $value), 0);
}

sub _kind_int {
  my ($name, $value, $entry) = @_;
  SauronAPI::Exception->validation("Invalid integer '$value' for '$name'")
    unless $value =~ /^-?\d+$/;
  return ([$entry->{col} . ' = ?'], [$value], _echo($name, $value), 0);
}

sub _kind_cidr {
  my ($name, $value, $entry) = @_;
  my $within = $entry->{within};
  if ($value =~ m{/}) {
    SauronAPI::Exception->validation("Invalid CIDR '$value' for '$name'") unless is_cidr($value);
    my $op = $within ? '<<=' : '=';
    return ([$entry->{col} . " $op ?"], [$value], _echo($name, $value), 0);
  }
  if ($within) {
    SauronAPI::Exception->validation("Invalid IP address '$value' for '$name'") unless is_ip($value);
    return ([$entry->{col} . ' = ?'], [$value], _echo($name, $value), 0);
  }
  SauronAPI::Exception->validation("Invalid CIDR '$value' for '$name' (prefix length required)");
}

sub _kind_date_range {
  my ($name, $value, $entry) = @_;
  my $epoch = _day_epoch($name, $value);
  if ($entry->{bound} eq 'to') {
    return ([$entry->{col} . ' <= ?'], [$epoch + 86399], _echo($name, $value), 0);
  }
  return ([$entry->{col} . ' >= ?'], [$epoch], _echo($name, $value), 0);
}

sub _kind_custom {
  my ($name, $value, $entry) = @_;
  my $res = $entry->{code}->($value);
  return (
    $res->{clauses} // [],
    $res->{bind}    // [],
    $res->{echo}    // _echo($name, $value),
    $res->{empty}   // 0,
  );
}

sub _day_epoch {
  my ($name, $value) = @_;
  SauronAPI::Exception->validation("Invalid date '$value' for '$name' (expected YYYY-MM-DD)")
    unless defined $value && $value =~ /^(\d{4})-(\d{2})-(\d{2})$/;
  my ($y, $m, $d) = ($1, $2, $3);
  my $epoch = eval { timegm(0, 0, 0, $d, $m - 1, $y) };
  SauronAPI::Exception->validation("Invalid date '$value' for '$name' (expected YYYY-MM-DD)")
    if $@ || !defined $epoch;
  my @gm = gmtime($epoch);
  SauronAPI::Exception->validation("Invalid date '$value' for '$name' (expected YYYY-MM-DD)")
    unless ($gm[5] + 1900) == $y && ($gm[4] + 1) == $m && $gm[3] == $d;
  return $epoch;
}

# ---------------------------------------------------------------------------

sub parse_sort {
  my ($param, $columns, %opts) = @_;

  my $default  = $opts{default};
  my $tiebreak = $opts{tiebreak} // 'id';
  die 'parse_sort requires a default field' unless defined $default;

  my @keys;
  if (defined $param && $param ne '') {
    for my $part (split /,/, $param) {
      my ($field, $dir) = split /:/, $part, 2;
      my $col = $columns->{$field // ''};
      SauronAPI::Exception->validation(
        "Unknown sort field '" . (defined $field ? $field : '') . "' (allowed: " .
        join(', ', sort keys %$columns) . ')'
      ) unless $col;
      $dir = 'asc' unless defined $dir && $dir ne '';
      SauronAPI::Exception->validation("Invalid sort direction '$dir' (allowed: asc, desc)")
        unless $dir =~ /^(?:asc|desc)$/;
      push @keys, { field => $field, col => $col, dir => $dir };
    }
  }
  push @keys, { field => $default, col => $columns->{$default}, dir => 'asc' } unless @keys;
  return { keys => \@keys, tiebreak => $tiebreak };
}

sub sort_sql {
  my ($sort) = @_;
  return 'ORDER BY ' . join(', ',
    (map { "$_->{col} $_->{dir} NULLS LAST" } @{$sort->{keys}}),
    $sort->{tiebreak} . ' asc'
  );
}

sub sort_echo {
  my ($sort) = @_;
  return [ map { { name => $_->{field}, direction => $_->{dir} } } @{$sort->{keys}} ];
}

# ---------------------------------------------------------------------------

sub list_metadata {
  my ($page, $per_page, $sort, $filters) = @_;

  return {
    pagination => {
      total       => 0,
      page        => $page,
      per_page    => $per_page,
      total_pages => 0,
    },
    sort    => $sort // [],
    filters => $filters // [],
  };
}

sub set_total {
  my ($meta, $total) = @_;
  $meta->{pagination}{total} = $total;
  my $pp = $meta->{pagination}{per_page};
  $meta->{pagination}{total_pages} = $pp > 0 ? int(($total + $pp - 1) / $pp) : 0;
}

1;
