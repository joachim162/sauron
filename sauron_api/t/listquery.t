use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";

use SauronAPITest;
use SauronAPI::Exception ();
use SauronAPI::ListQuery qw(
  compile_filters parse_sort sort_sql sort_echo list_metadata set_total
);

# Unit tests for the shared list-query compiler (docs/host-filtering-
# architecture-review.md). The regex kind probes PostgreSQL, so like the
# controller-parity suites this needs the test database.

Sauron::Sauron::load_config();
Sauron::DB::db_connect();

my %SPEC = (
  name       => { kind => 'regex', col => 'z.name' },
  hinfo      => { kind => 'regex_any', cols => ['h.hinfo_hw', 'h.hinfo_sw'] },
  ether      => { kind => 'regex', col => 'h.ether',
                  transform => sub { my $p = uc shift; $p =~ s/[^0-9A-F]//g; $p } },
  type       => { kind => 'enum', col => 'z.type', values => [qw(M S H F C A)] },
  reverse    => { kind => 'bool', col => 'z.reverse' },
  vlan       => { kind => 'int', col => 'n.vlan' },
  net        => { kind => 'cidr', col => 'n.net', within => 1 },
  expiration => { kind => 'date_range', col => 'z.expiration' },
  ip         => { kind => 'custom', code => sub {
    my ($value) = @_;
    my $op = $value =~ m{/} ? '<<=' : '=';
    return {
      clauses => ["EXISTS (SELECT 1 FROM a_entries ae WHERE ae.host = h.id AND ae.ip $op ?)"],
      bind    => [$value],
    };
  } },
);

my %COLS = (
  name => 'z.name',
  type => 'z.type',
);

sub _err {
  my ($code) = @_;
  return undef if eval { $code->(); 1 };
  return $@;
}

subtest 'no filters' => sub {
  my $r = compile_filters({}, \%SPEC);
  is($r->{where}, '', 'no filters -> empty where');
  is_deeply($r->{bind}, [], 'no binds');
  is_deeply($r->{echo}, [], 'no echo');
  is($r->{empty}, 0, 'not empty');
};

subtest 'regex kind' => sub {
  my $r = compile_filters({ name => 'foo' }, \%SPEC);
  is($r->{where}, 'z.name ~* ?');
  is_deeply($r->{bind}, ['foo']);
  is_deeply($r->{echo}, [{ name => 'name', value => 'foo' }]);
};

subtest 'regex transform' => sub {
  my $r = compile_filters({ ether => 'aa:bb' }, \%SPEC);
  is($r->{where}, 'h.ether ~* ?');
  is_deeply($r->{bind}, ['AABB'], 'transform applied after validation');
};

subtest 'regex_any kind' => sub {
  my $r = compile_filters({ hinfo => 'x' }, \%SPEC);
  is($r->{where}, '(h.hinfo_hw ~* ? OR h.hinfo_sw ~* ?)', 'OR group is parenthesized');
  is_deeply($r->{bind}, ['x', 'x']);
};

subtest 'regex dialect is PostgreSQL, not Perl' => sub {
  for my $p ('a{2,1}', '\Kfoo', 'foo++') {
    my $e = _err(sub { compile_filters({ name => $p }, \%SPEC) });
    isa_ok($e, 'SauronAPI::Exception', "$p throws");
    is($e->status, 400, "$p -> 400");
    like($e->message, qr/Invalid regular expression/, "$p message");
  }
};

subtest 'enum kind' => sub {
  my $r = compile_filters({ type => 'M' }, \%SPEC);
  is($r->{where}, 'z.type = ?');
  is_deeply($r->{bind}, ['M']);

  my $e = _err(sub { compile_filters({ type => 'X' }, \%SPEC) });
  is($e->status, 400, 'invalid enum -> 400');
  like($e->message, qr/Invalid value 'X' for 'type' \(allowed: M, S, H, F, C, A\)/);
};

subtest 'bool kind' => sub {
  my $r = compile_filters({ reverse => 'true' }, \%SPEC);
  is($r->{where}, 'z.reverse = ?');
  is_deeply($r->{bind}, ['t'], 'true binds t');

  is_deeply(compile_filters({ reverse => 'FALSE' }, \%SPEC)->{bind}, ['f'], 'FALSE binds f');
  is_deeply(compile_filters({ reverse => '1' }, \%SPEC)->{bind}, ['t'], '1 binds t');

  my $e = _err(sub { compile_filters({ reverse => 'yes' }, \%SPEC) });
  is($e->status, 400, 'invalid boolean -> 400');
};

subtest 'int kind' => sub {
  my $r = compile_filters({ vlan => '12' }, \%SPEC);
  is($r->{where}, 'n.vlan = ?');
  is_deeply($r->{bind}, ['12']);

  my $e = _err(sub { compile_filters({ vlan => '1.5' }, \%SPEC) });
  is($e->status, 400, 'non-integer -> 400');
};

subtest 'cidr kind' => sub {
  my $r = compile_filters({ net => '10.0.0.0/24' }, \%SPEC);
  is($r->{where}, 'n.net <<= ?', 'CIDR -> containment');
  is_deeply($r->{bind}, ['10.0.0.0/24']);

  $r = compile_filters({ net => '10.0.0.1' }, \%SPEC);
  is($r->{where}, 'n.net >>= ?', 'bare address -> containing net');
  is_deeply($r->{bind}, ['10.0.0.1']);

  for my $bad (qw(10.0.0.999 10.0.0.0/33 banana)) {
    my $e = _err(sub { compile_filters({ net => $bad }, \%SPEC) });
    is($e->status, 400, "'$bad' -> 400");
  }

  my %exact = (net => { kind => 'cidr', col => 'n.net' });
  my $r2 = compile_filters({ net => '10.0.0.0/24' }, \%exact);
  is($r2->{where}, 'n.net = ?', 'without within: CIDR is exact match');
  my $e = _err(sub { compile_filters({ net => '10.0.0.1' }, \%exact) });
  is($e->status, 400, 'without within: bare address rejected');
};

subtest 'date_range kind' => sub {
  my $r = compile_filters(
    { expiration_from => '2024-01-01', expiration_to => '2024-12-31' }, \%SPEC);
  is($r->{where}, 'z.expiration >= ? AND z.expiration <= ?');
  my ($from, $to) = @{$r->{bind}};
  is($to - $from, 365 * 86400 + 86399, 'to bound is inclusive of the whole day');
  is_deeply($r->{echo}, [
    { name => 'expiration_from', value => '2024-01-01' },
    { name => 'expiration_to',   value => '2024-12-31' },
  ], 'from/to echoed as separate params');

  for my $bad (qw(2024-13-01 2024-02-30 not-a-date)) {
    my $e = _err(sub { compile_filters({ expiration_from => $bad }, \%SPEC) });
    is($e->status, 400, "$bad -> 400");
    like($e->message, qr/Invalid date/, "$bad message");
  }
};

subtest 'custom kind' => sub {
  my $r = compile_filters({ ip => '10.0.0.5' }, \%SPEC);
  is($r->{where},
    'EXISTS (SELECT 1 FROM a_entries ae WHERE ae.host = h.id AND ae.ip = ?)');
  is_deeply($r->{bind}, ['10.0.0.5']);
  is_deeply($r->{echo}, [{ name => 'ip', value => '10.0.0.5' }], 'default echo');

  $r = compile_filters({ ip => '10.0.0.0/8' }, \%SPEC);
  like($r->{where}, qr/ae\.ip <<= \?/, 'operator chosen by value shape');
};

subtest 'custom empty result and echo override' => sub {
  my %spec = (x => { kind => 'custom', code => sub {
    my ($v) = @_;
    return {
      clauses => [],
      bind    => [],
      echo    => [{ name => 'x', value => $v }, { name => 'x_extra', value => 'y' }],
      empty   => 1,
    };
  } });
  my $r = compile_filters({ x => 'val' }, \%spec);
  is($r->{empty}, 1, 'empty flag propagates');
  is($r->{where}, '', 'no clauses');
  is_deeply($r->{echo},
    [{ name => 'x', value => 'val' }, { name => 'x_extra', value => 'y' }],
    'callback echo overrides the default');
};

subtest 'AND composition, ignore defaults, echo order' => sub {
  my $r = compile_filters(
    { name => 'a', type => 'M', page => 2, per_page => 10, sort => 'name' },
    \%SPEC);
  is($r->{where}, 'z.name ~* ? AND z.type = ?', 'filters AND-compose');
  is_deeply($r->{bind}, ['a', 'M']);
  is_deeply($r->{echo}, [
    { name => 'name', value => 'a' },
    { name => 'type', value => 'M' },
  ], 'echo sorted by param name');
};

subtest 'ignore list adds to the built-ins' => sub {
  my $r = compile_filters({ list => 'sub', page => 1 }, {}, ignore => [qw(list)]);
  is($r->{where}, '', 'view-mode param ignored alongside page/per_page/sort');
};

subtest 'unknown filter' => sub {
  my $e = _err(sub { compile_filters({ bogus => 'x' }, \%SPEC) });
  is($e->status, 400);
  like($e->message, qr/Unknown filter 'bogus'/);
};

subtest 'empty string values are skipped' => sub {
  my $r = compile_filters({ name => '' }, \%SPEC);
  is($r->{where}, '', 'empty param produces no clause');
  is_deeply($r->{echo}, []);
};

subtest 'repeated params take the last value' => sub {
  my $r = compile_filters({ name => ['a', 'b'] }, \%SPEC);
  is_deeply($r->{bind}, ['b']);
};

subtest 'parse_sort' => sub {
  my $s = parse_sort(undef, \%COLS, default => 'name', tiebreak => 'z.id');
  is_deeply($s->{keys}, [{ field => 'name', col => 'z.name', dir => 'asc' }],
    'default applied when param absent');
  is($s->{tiebreak}, 'z.id');

  $s = parse_sort('', \%COLS, default => 'name', tiebreak => 'z.id');
  is_deeply($s->{keys}, [{ field => 'name', col => 'z.name', dir => 'asc' }],
    'default applied for empty param');

  $s = parse_sort('type:desc,name', \%COLS, default => 'name', tiebreak => 'z.id');
  is_deeply($s->{keys}, [
    { field => 'type', col => 'z.type', dir => 'desc' },
    { field => 'name', col => 'z.name', dir => 'asc' },
  ], 'multi-field sort, bare field defaults to asc');
  is(sort_sql($s), 'ORDER BY z.type desc NULLS LAST, z.name asc NULLS LAST, z.id asc',
    'sort_sql with NULLS LAST and id tiebreak');
  is_deeply(sort_echo($s), [
    { name => 'type', direction => 'desc' },
    { name => 'name', direction => 'asc' },
  ], 'sort echo shape');
};

subtest 'parse_sort errors' => sub {
  my $e = _err(sub { parse_sort('bogus', \%COLS, default => 'name', tiebreak => 'z.id') });
  is($e->status, 400);
  like($e->message, qr/Unknown sort field 'bogus' \(allowed: name, type\)/);

  $e = _err(sub { parse_sort('name:up', \%COLS, default => 'name', tiebreak => 'z.id') });
  is($e->status, 400);
  like($e->message, qr/Invalid sort direction 'up' \(allowed: asc, desc\)/);
};

subtest 'list_metadata and set_total' => sub {
  my $meta = list_metadata(1, 50, [], []);
  is_deeply($meta, {
    pagination => { total => 0, page => 1, per_page => 50, total_pages => 0 },
    sort       => [],
    filters    => [],
  }, 'metadata envelope shape');

  for my $case ([0, 50, 0], [50, 50, 1], [51, 50, 2], [1, 50, 1], [10, 3, 4]) {
    my ($total, $pp, $pages) = @$case;
    my $m = list_metadata(2, $pp, [], []);
    set_total($m, $total);
    is($m->{pagination}{total}, $total);
    is($m->{pagination}{total_pages}, $pages, "total $total / per_page $pp -> $pages pages");
  }
};

done_testing();
