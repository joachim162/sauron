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
  ok(ref $json eq 'HASH' && ref $json->{data} eq 'ARRAY', 'response is the paginated envelope');
  my $data = $json->{data};
  cmp_ok(scalar @$data, '>=', 1, 'at least one network');

  my $found = (grep { $_->{id} == $nets[0] } @$data)[0];
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
  ok(ref $json eq 'HASH' && ref $json->{data} eq 'ARRAY', 'response is the paginated envelope');
  cmp_ok(scalar @{$json->{data}}, '>=', 1, 'server-R user sees networks');
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
  my ($found) = grep { $_->{id} == $nets[0] } @{$json->{data}};
  ok($found, 'found test net in list');
  is($found->{vlan},      $vlan_id,           'vlan id present');
  is($found->{vlan_name}, "test-vlan-${pid}", 'vlan_name enriched');

  $t->get_ok("$BASE/networks/$NETNAME" => $VLANUSER)->status_is(200);
  $json = $t->tx->res->json;
  is($json->{vlan},      $vlan_id,           'get_net vlan id present');
  is($json->{vlan_name}, "test-vlan-${pid}", 'get_net vlan_name enriched');

  $t->get_ok("$BASE/networks" => $RUSER)->status_is(200);
  $json = $t->tx->res->json;
  ($found) = grep { $_->{id} == $nets[0] } @{$json->{data}};
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

# ========================================================================
# PAGINATION (always-on envelope)
# ========================================================================

subtest 'GET networks - always-on pagination envelope' => sub {
  # Baseline over whatever nets exist on the fixture server
  $t->get_ok("$BASE/networks?page=1&per_page=1" => $SUPER)->status_is(200);
  my $baseline = $t->tx->res->json->{metadata}{pagination}{total};

  # Add 5 non-overlapping top-level networks
  Sauron::BackEnd::set_muser('test');
  my @new_ids;
  for my $n (1 .. 5) {
    my $id = Sauron::BackEnd::add_net({
      server => $srv,
      net    => "10.${\(150 + $n)}.${OCTET}.0/24",
      netname => "page-net${n}-${pid}",
      name   => "Pagination net $n",
      subnet => 'f',
      dummy  => 'f',
    });
    ok($id > 0, "created pagination net $n (id=$id)");
    push @new_ids, $id;
  }
  push @nets, @new_ids;

  # No params: envelope with defaults, all fixture nets on the default page
  $t->get_ok("$BASE/networks" => $SUPER)->status_is(200);
  my $env = $t->tx->res->json;
  ok(ref $env eq 'HASH' && ref $env->{data} eq 'ARRAY', 'no params: envelope, no bare array');
  is($env->{metadata}{pagination}{page}, 1, 'default page is 1');
  is($env->{metadata}{pagination}{per_page}, 50, 'default per_page is 50');
  is($env->{metadata}{pagination}{total}, $baseline + 5, 'total covers the whole set');
  is(scalar(grep { $_->{netname} =~ /^page-net\d-${pid}$/ } @{$env->{data}}), 5,
     'all 5 new nets on the default page');

  # Only page without per_page: still the envelope, default per_page
  $t->get_ok("$BASE/networks?page=1" => $SUPER)->status_is(200);
  is($t->tx->res->json->{metadata}{pagination}{per_page}, 50,
     'page alone keeps the envelope with default per_page');

  # Envelope with both params
  $t->get_ok("$BASE/networks?page=1&per_page=2" => $SUPER)
    ->status_is(200)
    ->json_is('/metadata/pagination/page'        => 1)
    ->json_is('/metadata/pagination/per_page'    => 2)
    ->json_is('/metadata/pagination/total'       => $baseline + 5)
    ->json_is('/metadata/pagination/total_pages' => int(($baseline + 5 + 1) / 2))
    ->json_is('/metadata/sort'                   => [])
    ->json_is('/metadata/filters'                => []);
  is(scalar @{$t->tx->res->json->{data}}, 2, 'page 1 holds 2 rows');

  # Pages cover the full set exactly, without duplicates, and match the
  # default-page set (order-insensitive).
  my @paged;
  my $pages = $t->tx->res->json->{metadata}{pagination}{total_pages};
  for my $p (1 .. $pages) {
    $t->get_ok("$BASE/networks?page=$p&per_page=2" => $SUPER)->status_is(200);
    push @paged, @{$t->tx->res->json->{data}};
  }
  is(scalar @paged, $baseline + 5, 'pages cover the full filtered set exactly');
  my %seen;
  $seen{$_->{id} . '/' . $_->{net}}++ for @paged;
  is(scalar(grep { $_ != 1 } values %seen), 0, 'no duplicate rows across pages');

  my %default_page = map { $_->{id} . '/' . $_->{net} => 1 } @{$env->{data}};
  is_deeply(\%seen, \%default_page, 'paged set equals the default-page set');

  # New nets are reachable through paging
  my ($found) = grep { $_->{netname} && $_->{netname} eq "page-net3-${pid}" } @paged;
  ok($found, 'page-net3 present across pages');

  # Bounds and enum validation
  $t->get_ok("$BASE/networks?page=0&per_page=2" => $SUPER)->status_is(400);
  $t->get_ok("$BASE/networks?page=1&per_page=101" => $SUPER)->status_is(400);
  $t->get_ok("$BASE/networks?list=bogus" => $SUPER)->status_is(400);
};

subtest 'GET networks - free list mode returns unallocated blocks' => sub {
  # Top-level net /24 with one /26 subnet at the start: the remaining
  # address space must surface as id=-1 pseudo rows in the free list mode.
  Sauron::BackEnd::set_muser('test');
  my $top = Sauron::BackEnd::add_net({
    server => $srv, net => "10.160.${OCTET}.0/24", netname => "free-top-${pid}",
    name => 'Free blocks test', subnet => 'f', dummy => 'f',
  });
  ok($top > 0, "created top net (id=$top)");
  my $sub = Sauron::BackEnd::add_net({
    server => $srv, net => "10.160.${OCTET}.0/26", netname => "free-sub-${pid}",
    name => 'Subnet covering front quarter', subnet => 't', dummy => 'f',
  });
  ok($sub > 0, "created subnet (id=$sub)");
  push @nets, $top, $sub;

  # The removed ?free= boolean is ignored: the request behaves like the
  # default list=all and shows no gap rows.
  $t->get_ok("$BASE/networks?free=1&per_page=100" => $SUPER)->status_is(200);
  my $body = $t->tx->res->json->{data};
  is(scalar(grep { $_->{id} == -1 } @$body), 0, 'legacy ?free=1 param ignored: no gap rows');

  # list=free includes the gap rows; totals cover the UNION (single page)
  $t->get_ok("$BASE/networks?list=free&per_page=100" => $SUPER)->status_is(200);
  $body = $t->tx->res->json->{data};
  my @gaps = grep { $_->{id} == -1 } @$body;
  ok(@gaps > 0, 'list=free returns unallocated pseudo records (id=-1)')
    or diag("no id=-1 rows in free list!");
  # The gap space must lie inside the top net but outside its subnet
  ok((grep { $_->{net} =~ /^10\.160\.${OCTET}\./ } @gaps) > 0,
     'gap blocks cover the top net remainder')
    if @gaps > 0;
  is($t->tx->res->json->{metadata}{pagination}{total}, scalar(@$body),
     'totals include gap rows (single page)');
};

subtest 'GET networks - list modes filter server-side' => sub {
  # Dummy (virtual) net inside free-top, distinguishing sub from all
  Sauron::BackEnd::set_muser('test');
  my $dummy = Sauron::BackEnd::add_net({
    server => $srv, net => "10.160.${OCTET}.128/26", netname => "dummy-net-${pid}",
    name => 'Virtual grouping net', subnet => 't', dummy => 't',
  });
  ok($dummy > 0, "created dummy net (id=$dummy)");
  push @nets, $dummy;

  $t->get_ok("$BASE/networks?list=all&per_page=100" => $SUPER)->status_is(200);
  my %by_name = map { ($_->{netname} // '') => 1 } @{$t->tx->res->json->{data}};
  ok($by_name{"dummy-net-${pid}"}, 'list=all includes dummy nets');
  is(scalar(grep { $_->{id} == -1 } @{$t->tx->res->json->{data}}), 0,
     'list=all has no gap rows');

  $t->get_ok("$BASE/networks?list=sub&per_page=100" => $SUPER)->status_is(200);
  %by_name = map { ($_->{netname} // '') => 1 } @{$t->tx->res->json->{data}};
  ok(!$by_name{"dummy-net-${pid}"}, 'list=sub excludes dummy nets');
  ok($by_name{"free-sub-${pid}"},   'list=sub includes subnets');
  ok($by_name{"free-top-${pid}"},   'list=sub includes top-level nets');

  $t->get_ok("$BASE/networks?list=top&per_page=100" => $SUPER)->status_is(200);
  %by_name = map { ($_->{netname} // '') => 1 } @{$t->tx->res->json->{data}};
  ok($by_name{"free-top-${pid}"},    'list=top includes top-level nets');
  ok($by_name{"page-net1-${pid}"},   'list=top includes pagination nets');
  ok(!$by_name{"free-sub-${pid}"},   'list=top excludes subnets');
  ok(!$by_name{"dummy-net-${pid}"},  'list=top excludes dummy nets');
  ok(!$by_name{$NETNAME},            'list=top excludes the subnet fixture');
};

subtest 'GET networks - free list mode degrades to all for low-alevel users' => sub {
  $t->get_ok("$BASE/networks?list=free&per_page=100" => $RUSER)->status_is(200);
  my $free = $t->tx->res->json;
  is(scalar(grep { $_->{id} == -1 } @{$free->{data}}), 0,
     'no gap rows without ALEVEL_SHOW_UNALLOCATED_CIDRS');

  $t->get_ok("$BASE/networks?list=all&per_page=100" => $RUSER)->status_is(200);
  is($t->tx->res->json->{metadata}{pagination}{total},
     $free->{metadata}{pagination}{total},
     'downgraded free totals equal list=all totals');
};

done_testing();
