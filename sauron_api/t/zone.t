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
  ok(ref $body eq 'ARRAY', 'response is a bare array (no envelope)');
  my ($hit) = grep { $_->{name} eq "zone1-${pid}.example.com" } @$body;
  ok($hit, 'fixture zone present');
  is($hit->{id}, $z1, 'id matches');
  is($hit->{type}, 'M', 'type M');
  is($hit->{server_id}, $srv, 'server_id matches');
  ok(exists $hit->{reverse}, 'reverse key present');
};

subtest 'GET zones - fixture filtered for zone-R user, hidden for no-access' => sub {
  $t->get_ok($URL => $ZONE_R)->status_is(200);
  my ($hit_r) = grep { $_->{name} eq "zone1-${pid}.example.com" } @{$t->tx->res->json};
  ok($hit_r, 'zone-R user sees zone');

  $t->get_ok($URL => $NOACC)->status_is(200);
  my ($hit_n) = grep { $_->{name} eq "zone1-${pid}.example.com" } @{$t->tx->res->json};
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

subtest 'POST zones - reverse and explicit type rejected by schema (readOnly)' => sub {
  # ZoneFields marks both type and reverse readOnly: the API currently only
  # permits creating type-M forward zones. Assert the gate stays in place.
  $t->post_ok($URL => $SUPER => json => {
    name    => "10.99.0.0/24",
    reverse => JSON::PP::true,
  })
    ->status_is(400)
    ->json_has('/errors');

  $t->post_ok($URL => $SUPER => json => {
    name => "typed-${pid}.example.com",
    type => 'S',
  })
    ->status_is(400)
    ->json_has('/errors');
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
  # type and reverse are readOnly in the schema: rejected by OpenAPI
  # validation before reaching the repository.
  for my $case (['type', 'S'], ['reverse', JSON::PP::true]) {
    my ($field, $value) = @$case;
    $t->put_ok("$URL/zone1-${pid}.example.com" => $SUPER => json => { $field => $value })
      ->status_is(400)
      ->json_has('/errors');
  }

  # serial is not schema-gated: the repository enforces immutability.
  $t->put_ok("$URL/zone1-${pid}.example.com" => $SUPER => json => { serial => 42 })
    ->status_is(400)
    ->json_is('/error' => 'Bad Request')
    ->json_like('/message' => qr/immutable/);
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

done_testing();
