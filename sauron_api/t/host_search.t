use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/lib";

use SauronAPITest qw(
  setup_test_app
  create_test_user delete_test_user
  create_test_server delete_test_server
  create_test_zone delete_test_zone
  grant_zone_access
);

# Host search: filters, sorting and metadata echo (ADR 0007), on both the
# zone-scoped and the server-scoped host list endpoints.

my $t = setup_test_app();

my $pid = $$;
my (@users, @servers, @zones, @manual_sql);

sub _sql {
  my ($sql) = @_;
  Sauron::DB::db_exec($sql);
}

sub _one {
  my ($sql) = @_;
  my @q;
  Sauron::DB::db_query($sql, \@q);
  return $q[0][0];
}

END {
  for my $uid (@users) {
    eval { delete_test_user($uid); };
  }
  for my $zid (@zones) {
    eval { delete_test_zone($zid); };
  }
  for my $sid (@servers) {
    eval { delete_test_server($sid); };
  }
  for my $sql (reverse @manual_sql) {
    eval { _sql($sql); };
  }
}

# ========================================================================
# Fixtures
# ========================================================================

my $srv = create_test_server(name => "srv-search-${pid}");
my $z1  = create_test_zone(server_id => $srv, name => "zone-search1-${pid}.example.com");
my $z2  = create_test_zone(server_id => $srv, name => "zone-search2-${pid}.example.com");
push @servers, $srv;
push @zones, $z1, $z2;

my $super = create_test_user(username => "searchsuper_${pid}", email => "searchsuper_${pid}\@example.com", superuser => 1);
my $user  = create_test_user(username => "searchuser_${pid}",  email => "searchuser_${pid}\@example.com");
push @users, $super, $user;
grant_zone_access($user, $z1, 'R');
grant_zone_access($user, $z2, 'R');

sub _as_super { $t->reset_session; { 'X-Remote-User' => "searchsuper_${pid}\@example.com" } }
sub _as_user  { $t->reset_session; { 'X-Remote-User' => "searchuser_${pid}\@example.com" } }
my $SUPER = _as_super();
my $USER  = _as_user();

my $ZURL    = "/api/v1/servers/srv-search-${pid}/zones/zone-search1-${pid}.example.com/hosts";
my $SURL    = "/api/v1/servers/srv-search-${pid}/hosts";
my $ZONE1   = "zone-search1-${pid}.example.com";

# Groups: office (alevel 0), office-sub (alevel 1 — above the regular
# user's alevel of 0).
_sql("INSERT INTO groups (server,name,type,alevel,comment) VALUES (${srv},'office-${pid}',1,0,'test')")
  unless _one("SELECT id FROM groups WHERE server=${srv} AND name='office-${pid}'");
_sql("INSERT INTO groups (server,name,type,alevel,comment) VALUES (${srv},'office-sub-${pid}',1,1,'test')")
  unless _one("SELECT id FROM groups WHERE server=${srv} AND name='office-sub-${pid}'");
push @manual_sql, "DELETE FROM groups WHERE server=${srv} AND name IN ('office-${pid}','office-sub-${pid}')";
my $grp_office = _one("SELECT id FROM groups WHERE server=${srv} AND name='office-${pid}'");
my $grp_sub    = _one("SELECT id FROM groups WHERE server=${srv} AND name='office-sub-${pid}'");

# Hosts in zone 1.
sub _post_host {
  my ($json) = @_;
  $t->post_ok($ZURL => $SUPER => json => $json);
  my $res = $t->tx->res->json;
  die "host create failed: " . ($res->{message} // '?') unless $t->tx->res->code == 201;
  return $res;
}

my $web1 = _post_host({
  hostname => 'web1', type => 'host', ips => [{ ip => '10.0.0.10' }],
  ether => '001122334455', location => 'Rack 4', dept => 'IT',
  info => 'primary web server', model => 'Dell R740', serial => 'SN001',
  misc => 'blue', asset_id => 'ASSET001', hinfo_hw => 'Intel Xeon', hinfo_sw => 'Linux',
  txt_l => [{ txt => 'v=spf1 -all' }],
  grp => $grp_office,
});
my $web2 = _post_host({ hostname => 'web2', type => 'host', ips => [{ ip => '10.0.0.11' }] });
my $app1 = _post_host({ hostname => 'app1', type => 'host', ips => [{ ip => '10.0.0.12' }], location => 'Rack 5', dept => 'Ops' });
my $resv1 = _post_host({
  hostname => 'resv1', type => 'reservation', ips => [{ ip => '10.0.0.20' }],
  duid => 'AABBCCDDEEFF', iaid => 439041101,
});
my $alias1 = _post_host({ hostname => 'alias1', type => 'alias', cname_txt => "web1.${ZONE1}." });
my $wild = _post_host({ hostname => "*.wild-${pid}", type => 'alias', cname_txt => "web1.${ZONE1}." });
my $txt2 = _post_host({ hostname => 'txt2', type => 'host', ips => [{ ip => '10.0.0.30' }], txt_l => [{ txt => 'hello world' }] });
my $mxh = _post_host({ hostname => 'mxhost', type => 'host', ips => [{ ip => '10.0.0.31' }], mx_l => [{ pri => 10, mx => 'mail.example.com' }] });

# app1 belongs to office-sub via a subgroup entry.
_sql("INSERT INTO group_entries (host, grp) VALUES (${\($app1->{id})}, ${grp_sub})");
push @manual_sql, "DELETE FROM group_entries WHERE grp=${grp_sub}";

# MX template attached to mxhost (templates are zone-scoped, host's mx column).
_sql("INSERT INTO mx_templates (zone, alevel, name, comment) VALUES (${z1}, 0, 'mail-tmpl-${pid}', 'x')");
push @manual_sql, "DELETE FROM mx_templates WHERE zone IN (${z1},${z2}) AND name='mail-tmpl-${pid}'";
my $mx_tmpl = _one("SELECT id FROM mx_templates WHERE zone=${z1} AND name='mail-tmpl-${pid}'");
_sql("UPDATE hosts SET mx=${mx_tmpl} WHERE id=${\($mxh->{id})}");

# A host with an old creation date.
my $old = _post_host({ hostname => 'oldhost', type => 'host', ips => [{ ip => '10.0.0.32' }] });
_sql("UPDATE hosts SET cdate=1577836800 WHERE id=${\($old->{id})}"); # 2020-01-01 UTC

# Hosts in zone 2 (for server-scope tests).
$t->post_ok("/api/v1/servers/srv-search-${pid}/zones/zone-search2-${pid}.example.com/hosts" => $SUPER => json =>
  { hostname => 'web1', type => 'host', ips => [{ ip => '10.0.1.10' }], location => 'Basement' });

# ========================================================================
# Type filter
# ========================================================================

subtest 'type filter' => sub {
  $t->get_ok("$ZURL?type=host" => $SUPER)->status_is(200);
  my $domains = [ map { $_->{domain} } @{$t->tx->res->json->{data}} ];
  ok((grep { $_ eq 'web1' } @$domains) && (grep { $_ eq 'resv1' } @$domains), 'host includes reservation');
  ok(!(grep { $_ eq 'alias1' } @$domains), 'alias excluded');

  $t->get_ok("$ZURL?type=reservation" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['resv1'], 'reservation only');

  $t->get_ok("$ZURL?type=alias" => $SUPER)->status_is(200);
  my @aliases = sort map { $_->{domain} } @{$t->tx->res->json->{data}};
  ok((grep { $_ eq 'alias1' } @aliases) && (grep { $_ eq "*.wild-${pid}" } @aliases), 'alias matches both aliases');
};

subtest 'type filter echoes and counts' => sub {
  $t->get_ok("$ZURL?type=host" => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  is($j->{metadata}{pagination}{total}, scalar @{$j->{data}}, 'total equals filtered count');
  is_deeply($j->{metadata}{filters}, [{ name => 'type', value => 'host' }], 'filter echo');
  is_deeply($j->{metadata}{sort}, [{ name => 'domain', direction => 'asc' }], 'default sort echo');
};

# ========================================================================
# Free search and field filters
# ========================================================================

subtest 'q free search' => sub {
  $t->get_ok("$ZURL?q=Rack" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['app1', 'web1'], 'q matches location');

  $t->get_ok("$ZURL?q=^rack" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['app1', 'web1'], 'q case-insensitive');

  $t->get_ok("$ZURL?q=Ops" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['app1'], 'q matches dept');
};

subtest 'field regex filters' => sub {
  my %cases = (
    'location' => ['Rack', ['app1', 'web1']],
    'dept'     => ['^IT$', ['web1']],
    'info'     => ['primary', ['web1']],
    'model'    => ['R740', ['web1']],
    'serial'   => ['SN001', ['web1']],
    'misc'     => ['blue', ['web1']],
    'asset_id' => ['ASSET', ['web1']],
    'hinfo'    => ['Intel|Linux', ['web1']],
  );
  for my $param (sort keys %cases) {
    my ($value, $want) = @{$cases{$param}};
    $t->get_ok("$ZURL?$param=" . ($param eq 'location' ? 'Rack' : $value) => $SUPER)->status_is(200);
    my $got = [ map { $_->{domain} } @{$t->tx->res->json->{data}} ];
    is_deeply($got, $want, "$param filter") or diag explain $got;
  }
};

subtest 'ether, duid and iaid normalization' => sub {
  $t->get_ok("$ZURL?ether=00:11:22" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['web1'], 'ether with separators normalized');

  $t->get_ok("$ZURL?duid=aa:bb:cc" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['resv1'], 'duid normalized');

  $t->get_ok("$ZURL?iaid=0x1a2b3c4d" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['resv1'], 'iaid hex converted to decimal');
};

# ========================================================================
# Domain filter
# ========================================================================

subtest 'domain filter' => sub {
  $t->get_ok("$ZURL?domain=^web" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['web1', 'web2'], 'label regex');

  # Leading *. is literal, not a regex quantifier.
  $t->get_ok("$ZURL?domain=*.wild-${pid}" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ["*.wild-${pid}"], 'leading * literal');

  # FQDN does not match on the zone-scoped path (label only).
  $t->get_ok("$ZURL?domain=web1.${ZONE1}" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], [], 'zone path matches label only');
};

subtest 'domain filter matches FQDN on server path' => sub {
  $t->get_ok("$SURL?domain=web1.${ZONE1}\$" => $SUPER)->status_is(200);
  my @hits = grep { $_->{domain} eq 'web1' } @{$t->tx->res->json->{data}};
  is(scalar @hits, 1, 'fqdn match on server path');
  is($hits[0]{zone}, $ZONE1, 'fqdn matched the zone1 web1');

  $t->get_ok("$SURL?domain=web1" => $SUPER)->status_is(200);
  is(scalar(grep { $_->{domain} eq 'web1' } @{$t->tx->res->json->{data}}), 2, 'label matches both zones');
};

# ========================================================================
# IP filter
# ========================================================================

subtest 'ip filter' => sub {
  $t->get_ok("$ZURL?ip=10.0.0.10" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['web1'], 'bare address exact');

  $t->get_ok("$ZURL?ip=10.0.0.8/29" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['app1', 'web1', 'web2'], 'cidr containment');

  $t->get_ok("$ZURL?ip=10.0.0.0/24" => $SUPER)->status_is(200);
  is(scalar @{$t->tx->res->json->{data}}, 7, 'whole subnet includes reservation and extras');
};

# ========================================================================
# Group filter
# ========================================================================

subtest 'group filter: base and subgroups' => sub {
  $t->get_ok("$ZURL?group=office-${pid}" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['web1'], 'base group');

  $t->get_ok("$ZURL?group=office-sub-${pid}" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['app1'], 'subgroup via group_entries');
};

subtest 'group filter gated by alevel' => sub {
  # office-sub requires alevel 1; the regular user has alevel 0.
  $t->get_ok("$ZURL?group=office-sub-${pid}" => $USER)->status_is(400)
    ->json_like('/message' => qr/Unknown group/);
  $t->get_ok("$ZURL?group=office-${pid}" => $USER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['web1'], 'alevel-0 group usable');

  $t->get_ok("$ZURL?group=no-such-group" => $SUPER)->status_is(400)
    ->json_like('/message' => qr/Unknown group/);
};

subtest 'host_group enrichment is alevel-gated' => sub {
  $t->get_ok("$ZURL?domain=web1\$" => $SUPER)->status_is(200);
  is($t->tx->res->json->{data}[0]{host_group}, "office-${pid}", 'superuser sees group name');
  is($t->tx->res->json->{data}[0]{fqdn}, "web1.${ZONE1}", 'fqdn present');

  $t->get_ok("$ZURL?domain=app1\$" => $SUPER)->status_is(200);
  # app1's base grp is none; its subgroup is not the base group field.
  is($t->tx->res->json->{data}[0]{host_group}, undef, 'subgroup membership is not the base group');

  $t->get_ok("$ZURL?domain=web1\$" => $USER)->status_is(200);
  is($t->tx->res->json->{data}[0]{host_group}, "office-${pid}", 'alevel-0 group visible to user');

  # Detail response also carries host_group.
  $t->get_ok("$ZURL/web1" => $SUPER)->status_is(200);
  is($t->tx->res->json->{host_group}, "office-${pid}", 'detail host_group');
};

# ========================================================================
# TXT and MX filters
# ========================================================================

subtest 'txt filter' => sub {
  $t->get_ok("$ZURL?txt=spf1" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['web1'], 'txt entry regex');

  $t->get_ok("$ZURL?txt=hello" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['txt2'], 'other txt entry');

  $t->get_ok("$ZURL?txt=nothing-matches" => $SUPER)->status_is(200);
  is(scalar @{$t->tx->res->json->{data}}, 0, 'no match');

  # Without an explicit type only TXT-capable types are searched.
  $t->get_ok("$ZURL?txt=." => $SUPER)->status_is(200);
  my $types = [ map { $_->{type} } @{$t->tx->res->json->{data}} ];
  ok(!(grep { $_ !~ /^(host|mx|alias|alias_arec)$/ } @$types), 'narrowed to txt-capable types');

  # Explicitly incompatible type + txt yields an empty set, not silent ignore.
  $t->get_ok("$ZURL?txt=spf1&type=alias" => $SUPER)->status_is(200);
  is(scalar @{$t->tx->res->json->{data}}, 0, 'incompatible type + txt is empty');
  is($t->tx->res->json->{metadata}{pagination}{total}, 0, 'total is 0');

  $t->get_ok("$ZURL?txt=spf1&type=host" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['web1'], 'host type + txt');
};

subtest 'mx filter' => sub {
  $t->get_ok("$ZURL?mx=^mail-tmpl" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['mxhost'], 'mx template name regex');

  $t->get_ok("$ZURL?mx=MAIL-TMPL" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['mxhost'], 'mx is case-insensitive');

  $t->get_ok("$ZURL?mx=nomatch" => $SUPER)->status_is(200);
  is(scalar @{$t->tx->res->json->{data}}, 0, 'no match');
};

# ========================================================================
# Date range filters
# ========================================================================

subtest 'date range filters' => sub {
  $t->get_ok("$ZURL?cdate_from=2020-01-01&cdate_to=2020-01-31" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['oldhost'], 'range hits only old host');

  $t->get_ok("$ZURL?cdate_to=2020-12-31" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['oldhost'], 'upper bound excludes recent');

  $t->get_ok("$ZURL?cdate_from=2026-01-01" => $SUPER)->status_is(200);
  ok((grep { $_->{domain} eq 'web1' } @{$t->tx->res->json->{data}}), 'recent hosts pass from-bound');
  ok(!(grep { $_->{domain} eq 'oldhost' } @{$t->tx->res->json->{data}}), 'old host fails from-bound');
};

# ========================================================================
# Sorting
# ========================================================================

subtest 'sorting' => sub {
  $t->get_ok("$ZURL?sort=domain:desc" => $SUPER)->status_is(200);
  my @d = map { $_->{domain} } @{$t->tx->res->json->{data}};
  is($d[0], "*.wild-${pid}", 'desc puts wildcard label first (DB collation sorts * after letters)');
  my ($w1) = grep { $_ eq 'web1' } @d;
  my ($w2) = grep { $_ eq 'web2' } @d;
  ok((index(join(',', @d), 'web2,web1') // -1) >= 0 || ($d[0] eq 'web2'), 'web2 precedes web1 in desc order');
  is_deeply($t->tx->res->json->{metadata}{sort},
    [{ name => 'domain', direction => 'desc' }], 'sort echo');

  $t->get_ok("$ZURL?sort=ip" => $SUPER)->status_is(200);
  @d = map { $_->{domain} } @{$t->tx->res->json->{data}};
  is_deeply([ @d[0 .. 3] ], [qw(web1 web2 app1 resv1)], 'ip sort by primary address');

  $t->get_ok("$ZURL?sort=ip:desc" => $SUPER)->status_is(200);
  my @rows = @{$t->tx->res->json->{data}};
  is($rows[0]{domain}, 'oldhost', 'desc by ip (highest first)');
  is_deeply([ map { $_->{domain} } @rows[-2, -1] ], ['alias1', "*.wild-${pid}"],
    'address-less hosts last in desc, tiebroken by id');
  ok(!@{$rows[-1]{ips}}, 'last row has no addresses');

  $t->get_ok("$ZURL?sort=type,domain" => $SUPER)->status_is(200);
  @d = map { $_->{domain} } @{$t->tx->res->json->{data}};
  is($d[0], 'app1', 'multi-key sort (types asc, then domain)');

  $t->get_ok("$ZURL?sort=bogus" => $SUPER)->status_is(400)
    ->json_like('/message' => qr/Unknown sort field/);
  $t->get_ok("$ZURL?sort=domain:sideways" => $SUPER)->status_is(400)
    ->json_like('/message' => qr/Invalid sort direction/);
};

# ========================================================================
# Validation errors
# ========================================================================

subtest 'invalid filter values return 400' => sub {
  my @bad = (
    ['q=[unclosed', 'invalid regex'],
    ['domain=(?P<x>', 'invalid domain regex'],
    ['ip=999.999.1.1', 'invalid ip'],
    ['ip=10.0.0.0/99', 'invalid cidr'],
    ['cdate_from=2020-13-01', 'invalid month'],
    ['cdate_from=2020-02-30', 'impossible date'],
    ['cdate_from=not-a-date', 'not a date'],
    ['iaid=zzzz', 'invalid iaid'],
  );
  for my $case (@bad) {
    my ($qs, $label) = @$case;
    $t->get_ok("$ZURL?$qs" => $SUPER)->status_is(400, $label)
      ->json_is('/error' => 'Bad Request');
  }
};

# ========================================================================
# Composed filters
# ========================================================================

subtest 'filters compose with AND' => sub {
  $t->get_ok("$ZURL?type=host&dept=IT&ip=10.0.0.8/29" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{domain} } @{$t->tx->res->json->{data}} ], ['web1'], 'type+dept+ip');
  is_deeply($t->tx->res->json->{metadata}{filters},
    [ { name => 'type', value => 'host' }, { name => 'ip', value => '10.0.0.8/29' }, { name => 'dept', value => 'IT' } ],
    'multiple filters echoed');
};

subtest 'server path applies the same filters' => sub {
  $t->get_ok("$SURL?type=host&location=Basement" => $SUPER)->status_is(200);
  is_deeply([ map { $_->{zone} } @{$t->tx->res->json->{data}} ], ["zone-search2-${pid}.example.com"],
    'cross-zone filter narrows to zone2 host');
  is($t->tx->res->json->{metadata}{pagination}{total}, 1, 'total over filtered set');
};

subtest 'permission filtering composes with filters' => sub {
  my $no_access = create_test_user(username => "searchno_${pid}", email => "searchno_${pid}\@example.com");
  push @users, $no_access;
  $t->reset_session;
  my $NO = { 'X-Remote-User' => "searchno_${pid}\@example.com" };

  $t->get_ok("$SURL?type=host" => $NO)->status_is(200);
  is(scalar @{$t->tx->res->json->{data}}, 0, 'no zone access, no hosts');

  $t->get_ok("$SURL?domain=web1" => $NO)->status_is(200);
  is(scalar @{$t->tx->res->json->{data}}, 0, 'filters compose inside the allowlist');
};

done_testing();
