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
  grant_server_access
);

my $t = setup_test_app();

my $pid = $$;
my (@users, @servers, @nets);

END {
  for my $nid (@nets) {
    eval { Sauron::BackEnd::delete_net($nid); };
  }
  for my $sid (@servers) {
    eval { delete_test_server($sid); };
  }
  for my $uid (@users) {
    eval { delete_test_user($uid); };
  }
}

my $srv = create_test_server(name => "srv-net-${pid}", comment => 'Net CRUD test');
push @servers, $srv;

my $super = create_test_user(username => "netsuper_${pid}", email => "netsuper_${pid}\@example.com", superuser => 1);
my $user  = create_test_user(username => "netuser_${pid}",  email => "netuser_${pid}\@example.com");
push @users, $super, $user;
grant_server_access($user, $srv, 'RW');

sub _as_super {
  $t->reset_session;
  return { 'X-Remote-User' => "netsuper_${pid}\@example.com" };
}
sub _as_user {
  $t->reset_session;
  return { 'X-Remote-User' => "netuser_${pid}\@example.com" };
}
my $SUPER = _as_super();
my $USER  = _as_user();

my $BASE = "/api/v1/servers/srv-net-${pid}";
my $OCTET = $pid % 254 + 1;
my $CIDR = "10.88.${OCTET}.0/24";
my $NETNAME = "test-net-${pid}";

# ========================================================================
# CREATE
# ========================================================================

subtest 'POST /servers/{server}/networks - create a network' => sub {
  $t->post_ok("$BASE/networks" => $SUPER => json => {
    netname => $NETNAME,
    name    => 'Test Network',
    net     => $CIDR,
    subnet  => JSON::PP::true,
    comment => 'Created by net.t',
  })->status_is(201)->json_has('/id')->json_has('/server_id');

  my $json = $t->tx->res->json;
  is($json->{netname}, $NETNAME, 'netname matches');
  is($json->{net}, $CIDR, 'CIDR matches');
  is($json->{subnet},  JSON::PP::true,  'subnet is true');
  is($json->{comment}, 'Created by net.t', 'comment matches');
  ok($json->{range_start}, 'range_start auto-assigned');
  ok($json->{range_end},   'range_end auto-assigned');
  is($json->{no_dhcp}, JSON::PP::false, 'no_dhcp defaults to false');
  is($json->{dummy},   JSON::PP::false, 'dummy defaults to false');

  push @nets, $json->{id};
};

subtest 'POST /servers/{server}/networks - duplicate CIDR returns 409' => sub {
  $t->post_ok("$BASE/networks" => $SUPER => json => {
    netname => "${NETNAME}-dup",
    name    => 'Duplicate Network',
    net     => $CIDR,
  })->status_is(409);

  my $json = $t->tx->res->json;
  like($json->{message}, qr/already exists/i, 'duplicate error message');
};

subtest 'POST /servers/{server}/networks - missing required fields return 400' => sub {
  $t->post_ok("$BASE/networks" => $SUPER => json => {
    name => 'No netname',
    net  => $CIDR,
  })->status_is(400);

  $t->post_ok("$BASE/networks" => $SUPER => json => {
    netname => 'no-cidr',
    name    => 'No CIDR',
  })->status_is(400);

  $t->post_ok("$BASE/networks" => $SUPER => json => {
    netname => 'bad-cidr',
    name    => 'Bad CIDR',
    net     => 'not-a-cidr',
  })->status_is(400);
};

subtest 'POST /servers/{server}/networks - non-superuser with RW access' => sub {
  my $octet2 = ($pid + 1) % 254 + 1;
  my $cidr2 = "10.88.${octet2}.0/24";
  $t->post_ok("$BASE/networks" => $USER => json => {
    netname => "test-net-user-${pid}",
    name    => 'User Created Net',
    net     => $cidr2,
  })->status_is(201);

  my $json = $t->tx->res->json;
  push @nets, $json->{id};
};

subtest 'POST /servers/{server}/networks - no access returns 403' => sub {
  my $noob = create_test_user(username => "netnoob_${pid}", email => "netnoob_${pid}\@example.com");
  push @users, $noob;
  my $headers = { 'X-Remote-User' => "netnoob_${pid}\@example.com" };

  $t->post_ok("$BASE/networks" => $headers => json => {
    netname => "${NETNAME}-noob",
    name    => 'Noob Net',
    net     => "10.${pid}.99.0/24",
  })->status_is(403);
};

# ========================================================================
# LIST
# ========================================================================

subtest 'GET /servers/{server}/networks - list all' => sub {
  $t->get_ok("$BASE/networks" => $SUPER)->status_is(200);

  my $json = $t->tx->res->json;
  ok(ref $json eq 'ARRAY', 'response is an array');
  cmp_ok(scalar @$json, '>=', 1, 'at least one network');
};

subtest 'GET /servers/{server}/networks - filter by subnets' => sub {
  $t->get_ok("$BASE/networks?subnets=1" => $SUPER)->status_is(200);
  my $json = $t->tx->res->json;
  for my $net (@$json) {
    is($net->{subnet}, JSON::PP::true, "filtered: $net->{netname} is a subnet");
  }
};

# ========================================================================
# GET
# ========================================================================

subtest 'GET /servers/{server}/network/{net} - by netname' => sub {
  $t->get_ok("$BASE/network/$NETNAME" => $SUPER)->status_is(200);

  my $json = $t->tx->res->json;
  is($json->{net},    $CIDR,    'CIDR matches');
  is($json->{netname}, $NETNAME, 'netname matches');
  is($json->{subnet},  JSON::PP::true,  'subnet is true');
};

# CIDR-based lookup via URL works in production (wildcard route with
# x-mojo-placeholder: '#') but cannot be tested via Test::Mojo because
# the client normalizes '/' in the path before the route engine sees it.

subtest 'GET /servers/{server}/network/{net} - 404 for non-existent' => sub {
  $t->get_ok("$BASE/network/999.999.999.0/24" => $SUPER)->status_is(404);
  $t->get_ok("$BASE/network/nonexistent-net"   => $SUPER)->status_is(404);
};

# ========================================================================
# UPDATE
# ========================================================================

subtest 'PUT /servers/{server}/network/{net} - update fields' => sub {
  $t->put_ok("$BASE/network/$NETNAME" => $SUPER => json => {
    comment => 'Updated comment',
    alevel  => 5,
    no_dhcp => JSON::PP::true,
  })->status_is(200);

  my $json = $t->tx->res->json;
  is($json->{comment},  'Updated comment',   'comment updated');
  is($json->{alevel},   5,                   'alevel updated');
  is($json->{no_dhcp},  JSON::PP::true,      'no_dhcp updated');
  is($json->{netname},  $NETNAME,            'unchanged fields preserved');
  is($json->{net},      $CIDR,               'unchanged CIDR preserved');
};

subtest 'PUT /servers/{server}/network/{net} - partial update' => sub {
  $t->put_ok("$BASE/network/$NETNAME" => $SUPER => json => {
    comment => 'Partial update only',
  })->status_is(200);

  my $json = $t->tx->res->json;
  is($json->{comment}, 'Partial update only', 'comment changed');
  is($json->{alevel},  5, 'alevel unchanged from previous update');
  is($json->{no_dhcp}, JSON::PP::true, 'no_dhcp unchanged');
};

subtest 'PUT /servers/{server}/network/{net} - 404 for non-existent' => sub {
  $t->put_ok("$BASE/network/999.999.999.0/24" => $SUPER => json => {
    comment => 'nope',
  })->status_is(404);
};

# ========================================================================
# DELETE
# ========================================================================

subtest 'DELETE /servers/{server}/network/{net} - delete a network' => sub {
  my $del_octet = ($pid + 2) % 254 + 1;
  $t->post_ok("$BASE/networks" => $SUPER => json => {
    netname => "delete-me-${pid}",
    name    => 'To Be Deleted',
    net     => "10.88.${del_octet}.0/24",
  })->status_is(201);

  $t->delete_ok("$BASE/network/delete-me-${pid}" => $SUPER)->status_is(204);

  $t->get_ok("$BASE/network/delete-me-${pid}" => $SUPER)->status_is(404);
};

subtest 'DELETE /servers/{server}/network/{net} - 404 for non-existent' => sub {
  $t->delete_ok("$BASE/network/999.999.999.0/24" => $SUPER)->status_is(404);
};

# ========================================================================
# NOT FOUND (server)
# ========================================================================

subtest 'Non-existent server returns 404' => sub {
  $t->get_ok("/api/v1/servers/nonexistent-${pid}/networks" => $SUPER)->status_is(404);
  $t->get_ok("/api/v1/servers/nonexistent-${pid}/network/1.2.3.0/24" => $SUPER)->status_is(404);
};

done_testing();
