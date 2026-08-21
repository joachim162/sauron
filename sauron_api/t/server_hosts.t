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
  grant_server_access grant_zone_access
);

my $t = setup_test_app();

# ========================================================================
# Fixture setup
# ========================================================================

my $pid = $$;
my (@users, @servers, @zones, @hosts);

END {
  for my $hid (@hosts) { eval { Sauron::BackEnd::delete_host($hid) } if $hid && $hid > 0 }
  for my $uid (@users) { eval { delete_test_user($uid) } }
  for my $zid (@zones) { eval { delete_test_zone($zid) } }
  for my $sid (@servers) { eval { delete_test_server($sid) } }
}

my $srv = create_test_server(name => "srv-shosts-${pid}", comment => 'Server hosts test');
my $z1  = create_test_zone(server_id => $srv, name => "zone-shosts1-${pid}.example.com");
my $z2  = create_test_zone(server_id => $srv, name => "zone-shosts2-${pid}.example.com");
push @servers, $srv;
push @zones, $z1, $z2;

sub _add_host {
  my ($zone_id, $domain, $ip) = @_;
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $zone_id, domain => $domain, type => 1,
    ip => [[0, $ip, 't', 't', 2]],
  });
  die "Failed to create host $domain: $hid" unless $hid > 0;
  push @hosts, $hid;
  return $hid;
}

# Two hosts with the SAME domain across two zones (proves cross-zone listing
# and stable ordering), plus one unique host in a second zone.
_add_host($z1, "alpha-${pid}", '10.0.0.201');
_add_host($z2, "beta-${pid}",  '10.0.0.202');
_add_host($z2, "alpha-${pid}", '10.0.0.203');

my $super = create_test_user(username => "sh_super_${pid}", email => "sh_super_${pid}\@example.com", superuser => 1);
my $r1    = create_test_user(username => "sh_r1_${pid}",    email => "sh_r1_${pid}\@example.com");
my $srvr  = create_test_user(username => "sh_srvr_${pid}",  email => "sh_srvr_${pid}\@example.com");
my $noacc = create_test_user(username => "sh_noacc_${pid}", email => "sh_noacc_${pid}\@example.com");
push @users, $super, $r1, $srvr, $noacc;
grant_zone_access($r1, $z1, 'R');          # only zone 1
grant_server_access($srvr, $srv, 'R');     # mode 0: server R exposes all zones

sub _as {
  my ($u) = @_;
  $t->reset_session;
  return { 'X-Remote-User' => "${u}_${pid}\@example.com" };
}
my $SUPER = _as('sh_super');
my $R1    = _as('sh_r1');
my $SVRR  = _as('sh_srvr');
my $NOACC = _as('sh_noacc');

my $URL = "/api/v1/servers/srv-shosts-${pid}/hosts";

sub _super_all {
  $t->get_ok($URL => $SUPER)->status_is(200);
  return $t->tx->res->json;
}

# ========================================================================
# Tests
# ========================================================================

my $all;

subtest 'GET server hosts - envelope and cross-zone items' => sub {
  $all = _super_all();
  my $body = $all;
  ok(ref $body eq 'HASH' && ref $body->{data} eq 'ARRAY', 'paginated envelope');
  is($body->{metadata}{pagination}{page}, 1, 'default page 1');
  is($body->{metadata}{pagination}{per_page}, 50, 'default per_page 50');
  is_deeply($body->{metadata}{sort}, [], 'sort metadata present');
  is_deeply($body->{metadata}{filters}, [], 'filters metadata present');

  my $n = scalar @{$body->{data}};
  is($body->{metadata}{pagination}{total}, $n, 'total matches returned rows (server hosts is small)');

  my ($a1) = grep { $_->{domain} eq "alpha-${pid}" && $_->{zone_id} == $z1 } @{$body->{data}};
  my ($b2) = grep { $_->{domain} eq "beta-${pid}"  && $_->{zone_id} == $z2 } @{$body->{data}};
  ok($a1, 'alpha in zone1 present');
  ok($b2, 'beta in zone2 present');
  is($a1->{zone}, "zone-shosts1-${pid}.example.com", 'item carries zone name');
  is($b2->{zone}, "zone-shosts2-${pid}.example.com", 'item carries zone name for the other zone');
  is_deeply($a1->{ips}, ['10.0.0.201'], 'ips populated');
  is($a1->{server_id}, $srv, 'server_id matches');
};

subtest 'GET server hosts - duplicate domain appears once per zone' => sub {
  my $n_alpha = scalar grep { $_->{domain} eq "alpha-${pid}" } @{$all->{data}};
  is($n_alpha, 2, 'same hostname present in both zones');
  my @zones = sort map { $_->{zone_id} } grep { $_->{domain} eq "alpha-${pid}" } @{$all->{data}};
  is_deeply(\@zones, [$z1, $z2], 'one entry per zone');
};

subtest 'GET server hosts - ordered by domain, id across zones' => sub {
  my @seq = map { [$_->{domain}, $_->{id}] } @{$all->{data}};
  my @sorted = sort { ($a->[0] cmp $b->[0]) || ($a->[1] <=> $b->[1]) } @seq;
  is_deeply(\@seq, \@sorted, 'rows come back ordered by domain, then id');
  my @alpha = grep { $_->[0] eq "alpha-${pid}" } @seq;
  cmp_ok($alpha[0][1], '<', $alpha[1][1], 'alpha ordered by id across zones');
};

subtest 'GET server hosts - server-R user in mode 0 sees all zones' => sub {
  $t->get_ok($URL => $SVRR)->status_is(200);
  my $body = $t->tx->res->json;
  is($body->{metadata}{pagination}{total}, $all->{metadata}{pagination}{total},
     'server R grant exposes same total as superuser');
};

subtest 'GET server hosts - zone-R user sees only their zone' => sub {
  $t->get_ok($URL => $R1)->status_is(200);
  my $body = $t->tx->res->json;

  # Expected = superuser rows that belong to zone1 (incl. its zone-apex row).
  my @expected = grep { $_->{zone_id} == $z1 } @{$all->{data}};
  is($body->{metadata}{pagination}{total}, scalar @expected, 'total limited to visible zone');
  ok(scalar @{$body->{data}} >= 1, 'some rows returned');
  for my $item (@{$body->{data}}) {
    is($item->{zone_id}, $z1, 'every row is in zone1');
    is($item->{zone}, "zone-shosts1-${pid}.example.com", 'zone name matches');
  }
  ok((grep { $_->{domain} eq "beta-${pid}" } @{$body->{data}}) == 0, 'host in other zone is hidden');
};

subtest 'GET server hosts - no access user gets empty list, not 403' => sub {
  $t->get_ok($URL => $NOACC)->status_is(200);
  my $body = $t->tx->res->json;
  is_deeply($body->{data}, [], 'empty data');
  is($body->{metadata}{pagination}{total}, 0, 'zero total');
};

subtest 'GET server hosts - unknown server returns 404' => sub {
  $t->get_ok("/api/v1/servers/nosuchserver-shosts-${pid}/hosts" => $SUPER)
    ->status_is(404)
    ->json_is('/error' => 'Not Found');
};

subtest 'GET server hosts - invalid page returns 400' => sub {
  $t->get_ok("$URL?page=0" => $SUPER)->status_is(400);
};

subtest 'GET server hosts - pagination mechanics' => sub {
  my $total = $all->{metadata}{pagination}{total};
  $t->get_ok("$URL?per_page=1" => $SUPER)->status_is(200);
  my $b1 = $t->tx->res->json;
  is(scalar @{$b1->{data}}, 1, 'one row per page');
  is($b1->{metadata}{pagination}{total}, $total, 'exact total');
  is($b1->{metadata}{pagination}{total_pages}, $total, 'total pages');

  $t->get_ok("$URL?per_page=1&page=2" => $SUPER)->status_is(200);
  my $b2 = $t->tx->res->json;
  is(scalar @{$b2->{data}}, 1, 'page 2 has one row');
  isnt($b2->{data}[0]{id}, $b1->{data}[0]{id}, 'page 2 differs from page 1');
};

subtest 'GET zone hosts - items also carry zone name (regression)' => sub {
  my $zurl = "/api/v1/servers/srv-shosts-${pid}/zones/zone-shosts1-${pid}.example.com/hosts";
  $t->get_ok($zurl => $SUPER)->status_is(200);
  my ($hit) = grep { $_->{domain} eq "alpha-${pid}" } @{$t->tx->res->json->{data}};
  ok($hit, 'zone list has the host');
  is($hit->{zone}, "zone-shosts1-${pid}.example.com", 'zone name on zone-scoped list too');
};

done_testing();
