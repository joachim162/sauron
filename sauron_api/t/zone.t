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

my $pid = $$;
my (@users, @servers, @zones);

END {
  for my $uid (@users) {
    eval { delete_test_user($uid) };
  }
  for my $zid (@zones) {
    eval { delete_test_zone($zid) };
  }
  for my $sid (@servers) {
    eval { delete_test_server($sid) };
  }
}

my $srv = create_test_server(name => "srv-zone-${pid}", comment => 'Zone CRUD test');
my $z1  = create_test_zone(server_id => $srv, name => "zone1-${pid}.example.com");
push @servers, $srv;
push @zones, $z1;

my $super = create_test_user(username => "zsuper_${pid}", email => "zsuper_${pid}\@example.com", superuser => 1);
my $zr    = create_test_user(username => "zr_${pid}",  email => "zr_${pid}\@example.com");
my $zrw   = create_test_user(username => "zrw_${pid}", email => "zrw_${pid}\@example.com");
my $srw   = create_test_user(username => "zsrw_${pid}", email => "zsrw_${pid}\@example.com");
my $nouser = create_test_user(username => "zno_${pid}", email => "zno_${pid}\@example.com");
push @users, $super, $zr, $zrw, $srw, $nouser;
grant_zone_access($zr,  $z1, 'R');
grant_zone_access($zrw, $z1, 'RW');
grant_server_access($srw, $srv, 'RW');

sub _as {
  my ($u) = @_;
  $t->reset_session;
  return { 'X-Remote-User' => "${u}_${pid}\@example.com" };
}
my $SUPER = _as('zsuper');
my $ZONE_R  = _as('zr');
my $ZONE_RW = _as('zrw');
my $SVR_RW  = _as('zsrw');
my $NOACC   = _as('zno');

my $URL = "/api/v1/servers/srv-zone-${pid}/zones";

# ========================================================================
# Read paths
# ========================================================================

subtest 'GET zones - superuser sees fixture zone' => sub {
  $t->get_ok($URL => $SUPER)
    ->status_is(200);
  my $body = $t->tx->res->json;
  ok(ref $body eq 'HASH' && ref $body->{data} eq 'ARRAY', 'response is the paginated envelope');
  is($body->{metadata}{pagination}{page}, 1, 'default page 1');
  is($body->{metadata}{pagination}{per_page}, 50, 'default per_page 50');
  my ($hit) = grep { $_->{name} eq "zone1-${pid}.example.com" } @{$body->{data}};
  ok($hit, 'fixture zone present');
  is($hit->{id}, $z1, 'id matches');
  is($hit->{type}, 'M', 'type M');
  is($hit->{server_id}, $srv, 'server_id matches');
  ok(exists $hit->{reverse}, 'reverse key present');
};

subtest 'GET zones - fixture filtered for zone-R user, hidden for no-access' => sub {
  $t->get_ok($URL => $ZONE_R)->status_is(200);
  my ($hit_r) = grep { $_->{name} eq "zone1-${pid}.example.com" } @{$t->tx->res->json->{data}};
  ok($hit_r, 'zone-R user sees zone');

  $t->get_ok($URL => $NOACC)->status_is(200);
  my ($hit_n) = grep { $_->{name} eq "zone1-${pid}.example.com" } @{$t->tx->res->json->{data}};
  ok(!$hit_n, 'no-access user does not see zone');
};

subtest 'GET zone - fields' => sub {
  $t->get_ok("$URL/zone1-${pid}.example.com" => $SUPER)
    ->status_is(200)
    ->json_is('/id'        => $z1)
    ->json_is('/server_id' => $srv)
    ->json_is('/name'      => "zone1-${pid}.example.com")
    ->json_is('/type'      => 'M')
    ->json_is('/reverse'   => JSON::PP::false);
};

subtest 'GET zone - zone R user can read' => sub {
  $t->get_ok("$URL/zone1-${pid}.example.com" => $ZONE_R)
    ->status_is(200)
    ->json_is('/name' => "zone1-${pid}.example.com");
};

subtest 'GET zone - no access denied' => sub {
  $t->get_ok("$URL/zone1-${pid}.example.com" => $NOACC)
    ->status_is(403)
    ->json_is('/error' => 'Forbidden');
};

subtest 'GET zone - non-existent returns 404' => sub {
  $t->get_ok("$URL/nosuchzone-${pid}.example.com" => $SUPER)
    ->status_is(404)
    ->json_is('/error' => 'Not Found');
};

# ========================================================================
# Write paths
# ========================================================================

subtest 'POST zones - create' => sub {
  $t->post_ok($URL => $SUPER => json => {
    name       => "created-${pid}.example.com",
    comment    => 'created via API',
    hostmaster => "hostmaster.created-${pid}.example.com.",
    ttl        => 3600,
  })
    ->status_is(201)
    ->json_is('/name'    => "created-${pid}.example.com")
    ->json_is('/type'    => 'M')
    ->json_is('/comment' => 'created via API')
    ->json_is('/reverse' => JSON::PP::false);

  my $id = $t->tx->res->json->{id};
  push @zones, $id;
};

subtest 'POST zones - duplicate returns 409' => sub {
  $t->post_ok($URL => $SUPER => json => { name => "created-${pid}.example.com" })
    ->status_is(409)
    ->json_is('/error' => 'Conflict');
};

subtest 'POST zones - server RW user can create' => sub {
  $t->post_ok($URL => $SVR_RW => json => { name => "rwcreated-${pid}.example.com" })
    ->status_is(201)
    ->json_is('/name' => "rwcreated-${pid}.example.com");
  my $id = $t->tx->res->json->{id};
  push @zones, $id;
};

subtest 'POST zones - zone-RW (no server RW) denied' => sub {
  $t->post_ok($URL => $ZONE_RW => json => { name => "denied-${pid}.example.com" })
    ->status_is(403)
    ->json_is('/error' => 'Forbidden');
};

subtest 'POST zones - reverse zone from CIDR (CGI parity)' => sub {
  $t->post_ok($URL => $SUPER => json => {
    name    => "10.99.0.0/24",
    reverse => JSON::PP::true,
  })
    ->status_is(201)
    ->json_is('/type'       => 'M')
    ->json_is('/reverse'    => JSON::PP::true)
    ->json_is('/reversenet' => '10.99.0.0/24')
    ->json_like('/name'     => qr/in-addr\.arpa$/);

  my $id = $t->tx->res->json->{id};
  push @zones, $id;
};

subtest 'POST zones - invalid reverse zone name returns 400' => sub {
  $t->post_ok($URL => $SUPER => json => { name => "not-a-reverse-${pid}.example.com", reverse => JSON::PP::true })
    ->status_is(400)
    ->json_is('/error' => 'Bad Request')
    ->json_is('/message' => 'Invalid reverse zone name');
};

subtest 'POST zones - explicit type slave (CGI parity)' => sub {
  $t->post_ok($URL => $SUPER => json => { name => "slave-${pid}.example.com", type => 'S' })
    ->status_is(201)
    ->json_is('/type' => 'S');
  my $id = $t->tx->res->json->{id};
  push @zones, $id;
};

subtest 'POST zones - type enum enforced (CGI parity)' => sub {
  $t->post_ok($URL => $SUPER => json => { name => "badtype-${pid}.example.com", type => 'X' })
    ->status_is(400)
    ->json_is('/error' => 'Bad Request')
    ->json_like('/message' => qr/Invalid zone type/);

  # Reverse zones are master-only, as in the CGI form
  $t->post_ok($URL => $SUPER => json => { name => "revslave-${pid}.example.com", type => 'S', reverse => JSON::PP::true })
    ->status_is(400)
    ->json_is('/error' => 'Bad Request')
    ->json_like('/message' => qr/master/);
};

subtest 'POST zones - catalog zone gets TTL=0 and minimum=0 (RFC 9432)' => sub {
  $t->post_ok($URL => $SUPER => json => {
    name => "catalog-${pid}.example.com",
    type => 'C',
    ttl  => 9999,   # CGI ignores input TTL for catalog zones
  })
    ->status_is(201)
    ->json_is('/type' => 'C')
    ->json_is('/ttl'  => 0)
    ->json_is('/minimum' => 0);
  my $id = $t->tx->res->json->{id};
  push @zones, $id;
};

subtest 'PUT zone - scalar round-trip' => sub {
  $t->put_ok("$URL/zone1-${pid}.example.com" => $SUPER => json => {
    comment    => 'updated zone comment',
    hostmaster => "ops-${pid}.example.com.",
    ttl        => 7200,
    active     => JSON::PP::false,
  })
    ->status_is(200)
    ->json_is('/comment'    => 'updated zone comment')
    ->json_is('/hostmaster' => "ops-${pid}.example.com.")
    ->json_is('/ttl'        => 7200)
    ->json_is('/active'     => JSON::PP::false);

  $t->get_ok("$URL/zone1-${pid}.example.com" => $SUPER)
    ->status_is(200)
    ->json_is('/comment' => 'updated zone comment')
    ->json_is('/ttl'     => 7200);
};

subtest 'PUT zone - array field round-trip (txt replace-all)' => sub {
  $t->put_ok("$URL/zone1-${pid}.example.com" => $SUPER => json => {
    txt => [{ txt => 'v=spf1 -all', comment => 'spf' }],
  })
    ->status_is(200)
    ->json_is('/txt/0/txt'     => 'v=spf1 -all')
    ->json_is('/txt/0/comment' => 'spf');

  $t->put_ok("$URL/zone1-${pid}.example.com" => $SUPER => json => {
    txt => [{ txt => 'second' }],
  })
    ->status_is(200)
    ->json_is('/txt/0/txt' => 'second')
    ->json_is('/txt/1' => undef);
};

subtest 'PUT zone - immutable fields rejected' => sub {
  for my $case (['type', 'S'], ['reverse', JSON::PP::true], ['serial', 42]) {
    my ($field, $value) = @$case;
    $t->put_ok("$URL/zone1-${pid}.example.com" => $SUPER => json => { $field => $value })
      ->status_is(400)
      ->json_is('/error' => 'Bad Request')
      ->json_like('/message' => qr/immutable/);
  }
};

subtest 'PUT zone - zone RW user can update' => sub {
  $t->put_ok("$URL/zone1-${pid}.example.com" => $ZONE_RW => json => { comment => 'rw edit' })
    ->status_is(200)
    ->json_is('/comment' => 'rw edit');
};

subtest 'PUT zone - zone R user denied' => sub {
  $t->put_ok("$URL/zone1-${pid}.example.com" => $ZONE_R => json => { comment => 'r edit' })
    ->status_is(403)
    ->json_is('/error' => 'Forbidden');
};

subtest 'PUT zone - non-existent returns 404' => sub {
  $t->put_ok("$URL/nosuchzone-${pid}.example.com" => $SUPER => json => { comment => 'x' })
    ->status_is(404)
    ->json_is('/error' => 'Not Found');
};

subtest 'DELETE zone - server RW (not RWS) denied' => sub {
  $t->delete_ok("$URL/rwcreated-${pid}.example.com" => $SVR_RW)
    ->status_is(403)
    ->json_is('/error' => 'Forbidden');
};

subtest 'DELETE zone - delete then 404' => sub {
  $t->delete_ok("$URL/created-${pid}.example.com" => $SUPER)
    ->status_is(204);

  $t->get_ok("$URL/created-${pid}.example.com" => $SUPER)
    ->status_is(404);
};

# ========================================================================
# PAGINATION (always-on envelope) + AUTHZ ALLOWLIST TOTALS
# ========================================================================

subtest 'GET zones - pagination envelope and page coverage' => sub {
  $t->get_ok("$URL?page=1&per_page=1" => $SUPER)->status_is(200);
  my $total = $t->tx->res->json->{metadata}{pagination}{total};
  ok($total >= 5, "fixture zones present (total=$total)");

  $t->get_ok($URL => $SUPER)->status_is(200);
  my $env = $t->tx->res->json;
  is($env->{metadata}{pagination}{page}, 1, 'default page 1');
  is($env->{metadata}{pagination}{per_page}, 50, 'default per_page 50');
  is($env->{metadata}{pagination}{total}, $total, 'totals stable across requests');

  $t->get_ok("$URL?page=1&per_page=2" => $SUPER)->status_is(200);
  my $pages = $t->tx->res->json->{metadata}{pagination}{total_pages};
  my @paged;
  for my $p (1 .. $pages) {
    $t->get_ok("$URL?page=$p&per_page=2" => $SUPER)->status_is(200);
    push @paged, @{$t->tx->res->json->{data}};
  }
  is(scalar @paged, $total, 'pages cover the visible set exactly');
  my %seen;
  $seen{$_->{id}}++ for @paged;
  is(scalar(grep { $_ != 1 } values %seen), 0, 'no duplicate zones across pages');

  $t->get_ok("$URL?page=0&per_page=2" => $SUPER)->status_is(400);
  $t->get_ok("$URL?page=1&per_page=101" => $SUPER)->status_is(400);
};

subtest 'GET zones - totals reflect the authz allowlist' => sub {
  # Zone-R user: only their granted zone is counted
  $t->get_ok($URL => $ZONE_R)->status_is(200);
  my $env = $t->tx->res->json;
  is($env->{metadata}{pagination}{total}, 1, 'zone-R user totals exactly their visible zone');
  is($env->{data}[0]{name}, "zone1-${pid}.example.com", 'visible zone is the fixture zone');

  # No-access user: empty allowlist short-circuits to an empty page
  $t->get_ok($URL => $NOACC)->status_is(200);
  $env = $t->tx->res->json;
  is($env->{metadata}{pagination}{total}, 0, 'no-access user totals 0');
  is_deeply($env->{data}, [], 'no-access user data empty');
  is($env->{metadata}{pagination}{total_pages}, 0, 'no-access total_pages 0');

  # Server-RW user (PRIVILEGE_MODE 0 fallback): same totals as superuser
  $t->get_ok($URL => $SVR_RW)->status_is(200);
  my $svr_total = $t->tx->res->json->{metadata}{pagination}{total};
  $t->get_ok($URL => $SUPER)->status_is(200);
  is($svr_total, $t->tx->res->json->{metadata}{pagination}{total},
     'server-granted user totals match superuser (mode 0 fallback)');
};

done_testing();
