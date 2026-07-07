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

my $super  = create_test_user(username => "netsuper_${pid}",  email => "netsuper_${pid}\@example.com", superuser => 1);
my $rwuser = create_test_user(username => "netrw_${pid}",    email => "netrw_${pid}\@example.com");
my $ruser  = create_test_user(username => "netr_${pid}",     email => "netr_${pid}\@example.com");
push @users, $super, $rwuser, $ruser;
grant_server_access($rwuser, $srv, 'RW');
grant_server_access($ruser,  $srv, 'R');

sub _as_super {
  $t->reset_session;
  return { 'X-Remote-User' => "netsuper_${pid}\@example.com" };
}
sub _as_rwuser {
  $t->reset_session;
  return { 'X-Remote-User' => "netrw_${pid}\@example.com" };
}
sub _as_ruser {
  $t->reset_session;
  return { 'X-Remote-User' => "netr_${pid}\@example.com" };
}
my $SUPER  = _as_super();
my $RWUSER = _as_rwuser();
my $RUSER  = _as_ruser();

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

subtest 'POST /servers/{server}/networks - non-superuser with server RW is denied' => sub {
  my $octet2 = ($pid + 1) % 254 + 1;
  my $cidr2 = "10.88.${octet2}.0/24";
  $t->post_ok("$BASE/networks" => $RWUSER => json => {
    netname => "test-net-user-${pid}",
    name    => 'User Created Net',
    net     => $cidr2,
  })->status_is(403)
    ->json_is('/error' => 'Forbidden')
    ->json_is('/message' => 'Administrator privileges required');
};

subtest 'POST /servers/{server}/networks - no server access returns 403' => sub {
  my $noob = create_test_user(username => "netnoob_${pid}", email => "netnoob_${pid}\@example.com");
  push @users, $noob;
  my $headers = { 'X-Remote-User' => "netnoob_${pid}\@example.com" };

  $t->post_ok("$BASE/networks" => $headers => json => {
    netname => "${NETNAME}-noob",
    name    => 'Noob Net',
    net     => "10.${pid}.99.0/24",
  })->status_is(403)
    ->json_is('/error' => 'Forbidden')
    ->json_is('/message' => 'Administrator privileges required');
};

# ========================================================================
# LIST
# ========================================================================

subtest 'GET /servers/{server}/networks - summary list (superuser)' => sub {
  $t->get_ok("$BASE/networks" => $SUPER)->status_is(200);

  my $json = $t->tx->res->json;
  ok(ref $json eq 'ARRAY', 'response is an array');
  cmp_ok(scalar @$json, '>=', 1, 'at least one network');

  my $found = (grep { $_->{id} == $nets[0] } @$json)[0];
  ok($found, 'created network present in summary');
  is($found->{net},         $CIDR,              'summary net');
  is($found->{netname},     $NETNAME,           'summary netname');
  is($found->{name},        'Test Network',     'summary name');
  is($found->{dhcp},        JSON::PP::true,     'summary dhcp enabled');
  is($found->{vlan},        -1,                 'summary vlan none');
  is($found->{alevel},      0,                  'summary alevel');
  ok(!exists $found->{comment}, 'summary omits comment');
  ok(!exists $found->{server_id}, 'summary omits server_id');
};

subtest 'GET /servers/{server}/networks - server-R user can list' => sub {
  $t->get_ok("$BASE/networks" => $RUSER)->status_is(200);

  my $json = $t->tx->res->json;
  ok(ref $json eq 'ARRAY', 'response is an array');
  cmp_ok(scalar @$json, '>=', 1, 'server-R user sees networks');
};

# ========================================================================
# GET
# ========================================================================

subtest 'GET /servers/{server}/networks/{net} - by netname' => sub {
  $t->get_ok("$BASE/networks/$NETNAME" => $SUPER)->status_is(200);

  my $json = $t->tx->res->json;
  is($json->{net},    $CIDR,    'CIDR matches');
  is($json->{netname}, $NETNAME, 'netname matches');
  is($json->{subnet},  JSON::PP::true,  'subnet is true');
};

# CIDR-based lookup via URL works in production (wildcard route with
# x-mojo-placeholder: '#') but cannot be tested via Test::Mojo because
# the client normalizes '/' in the path before the route engine sees it.

subtest 'GET /servers/{server}/networks/{net} - 404 for non-existent' => sub {
  $t->get_ok("$BASE/networks/999.999.999.0/24" => $SUPER)->status_is(404);
  $t->get_ok("$BASE/networks/nonexistent-net"   => $SUPER)->status_is(404);
};

# ========================================================================
# UPDATE
# ========================================================================

subtest 'PUT /servers/{server}/networks/{net} - update fields' => sub {
  $t->put_ok("$BASE/networks/$NETNAME" => $SUPER => json => {
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

subtest 'PUT /servers/{server}/networks/{net} - partial update' => sub {
  $t->put_ok("$BASE/networks/$NETNAME" => $SUPER => json => {
    comment => 'Partial update only',
  })->status_is(200);

  my $json = $t->tx->res->json;
  is($json->{comment}, 'Partial update only', 'comment changed');
  is($json->{alevel},  5, 'alevel unchanged from previous update');
  is($json->{no_dhcp}, JSON::PP::true, 'no_dhcp unchanged');
};

subtest 'PUT /servers/{server}/networks/{net} - 404 for non-existent' => sub {
  $t->put_ok("$BASE/networks/999.999.999.0/24" => $SUPER => json => {
    comment => 'nope',
  })->status_is(404);
};

# ========================================================================
# DELETE
# ========================================================================

subtest 'DELETE /servers/{server}/networks/{net} - delete a network' => sub {
  my $del_octet = ($pid + 2) % 254 + 1;
  $t->post_ok("$BASE/networks" => $SUPER => json => {
    netname => "delete-me-${pid}",
    name    => 'To Be Deleted',
    net     => "10.88.${del_octet}.0/24",
  })->status_is(201);

  $t->delete_ok("$BASE/networks/delete-me-${pid}" => $SUPER)->status_is(204);

  $t->get_ok("$BASE/networks/delete-me-${pid}" => $SUPER)->status_is(404);
};

subtest 'DELETE /servers/{server}/networks/{net} - 404 for non-existent' => sub {
  $t->delete_ok("$BASE/networks/999.999.999.0/24" => $SUPER)->status_is(404);
};

# ========================================================================
# NOT FOUND (server)
# ========================================================================

subtest 'Non-existent server returns 404' => sub {
  $t->get_ok("/api/v1/servers/nonexistent-${pid}/networks" => $SUPER)->status_is(404);
  $t->get_ok("/api/v1/servers/nonexistent-${pid}/networks/1.2.3.0/24" => $SUPER)->status_is(404);
};

# ========================================================================
# VLAN name enrichment
# ========================================================================

subtest 'GET /servers/{server}/networks - vlan_name when authorized' => sub {
  Sauron::BackEnd::set_muser('test');
  my $vlan_id = Sauron::BackEnd::add_vlan({
    server  => $srv,
    name    => "test-vlan-${pid}",
    vlanno  => 100 + ($pid % 899),
    dhcp_l  => [],
    dhcp_l6 => [],
  });
  ok($vlan_id > 0, 'vlan created');

  Sauron::DB::db_exec("UPDATE nets SET vlan=$vlan_id WHERE id=$nets[0]");

  my $vlanuser = create_test_user(
    username => "netvlan_${pid}",
    email    => "netvlan_${pid}\@example.com",
  );
  push @users, $vlanuser;
  grant_server_access($vlanuser, $srv, 'R');
  Sauron::BackEnd::add_record('user_rights', {
    type => 2, ref => $vlanuser, rtype => 6, rref => 0, rule => 5,
  });
  my $VLANUSER = { 'X-Remote-User' => "netvlan_${pid}\@example.com" };

  $t->get_ok("$BASE/networks" => $VLANUSER)->status_is(200);
  my $json = $t->tx->res->json;
  my ($found) = grep { $_->{id} == $nets[0] } @$json;
  ok($found, 'found test net in list');
  is($found->{vlan},      $vlan_id,           'vlan id present');
  is($found->{vlan_name}, "test-vlan-${pid}", 'vlan_name enriched');

  $t->get_ok("$BASE/networks/$NETNAME" => $VLANUSER)->status_is(200);
  $json = $t->tx->res->json;
  is($json->{vlan},      $vlan_id,           'get_net vlan id present');
  is($json->{vlan_name}, "test-vlan-${pid}", 'get_net vlan_name enriched');

  $t->get_ok("$BASE/networks" => $RUSER)->status_is(200);
  $json = $t->tx->res->json;
  ($found) = grep { $_->{id} == $nets[0] } @$json;
  ok($found, 'found test net as low-alevel user');
  is($found->{vlan},      $vlan_id, 'vlan id still visible');
  is($found->{vlan_name}, undef,    'vlan_name hidden without ALEVEL_VLANS');

  Sauron::DB::db_exec("UPDATE nets SET vlan=-1 WHERE id=$nets[0]");
  Sauron::DB::db_exec("DELETE FROM vlans WHERE id=$vlan_id");
};

# ========================================================================
# Authorization aligned with legacy CGI
# ========================================================================

subtest 'GET /servers/{server}/networks/{net} - server-R user can read' => sub {
  $t->get_ok("$BASE/networks/$NETNAME" => $RUSER)->status_is(200);

  my $json = $t->tx->res->json;
  is($json->{net},     $CIDR,    'CIDR matches');
  is($json->{netname}, $NETNAME, 'netname matches');
};

subtest 'PUT /servers/{server}/networks/{net} - non-superuser is denied' => sub {
  $t->put_ok("$BASE/networks/$NETNAME" => $RWUSER => json => { comment => 'hacked' })
    ->status_is(403)
    ->json_is('/error' => 'Forbidden')
    ->json_is('/message' => 'Administrator privileges required');
};

subtest 'DELETE /servers/{server}/networks/{net} - non-superuser is denied' => sub {
  $t->delete_ok("$BASE/networks/$NETNAME" => $RWUSER)
    ->status_is(403)
    ->json_is('/error' => 'Forbidden')
    ->json_is('/message' => 'Administrator privileges required');
};

subtest 'Network access - user without server access is denied' => sub {
  my $noaccess = create_test_user(username => "netnoacc_${pid}", email => "netnoacc_${pid}\@example.com");
  push @users, $noaccess;
  my $HEADERS = { 'X-Remote-User' => "netnoacc_${pid}\@example.com" };

  $t->get_ok("$BASE/networks" => $HEADERS)->status_is(403)->json_is('/error' => 'Forbidden');
  $t->get_ok("$BASE/networks/${NETNAME}" => $HEADERS)->status_is(403)->json_is('/error' => 'Forbidden');
  $t->put_ok("$BASE/networks/${NETNAME}" => $HEADERS => json => { comment => 'hack' })->status_is(403)->json_is('/error' => 'Forbidden');
  $t->delete_ok("$BASE/networks/${NETNAME}" => $HEADERS)->status_is(403)->json_is('/error' => 'Forbidden');
};

done_testing();
