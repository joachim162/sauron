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

# ========================================================================
# Fixture setup
# ========================================================================

my $pid = $$;
my (@users, @servers);

END {
  for my $uid (@users) {
    eval { delete_test_user($uid); };
  }
  for my $sid (@servers) {
    eval { delete_test_server($sid); };
  }
}

my $srv = create_test_server(name => "srv-vlan-${pid}", comment => 'VLAN CRUD test');
push @servers, $srv;

my $super = create_test_user(username => "vlansuper_${pid}", email => "vlansuper_${pid}\@example.com", superuser => 1);
my $level5 = create_test_user(username => "vlanlvl_${pid}",   email => "vlanlvl_${pid}\@example.com");
my $low    = create_test_user(username => "vlanlow_${pid}",   email => "vlanlow_${pid}\@example.com");
my $rw     = create_test_user(username => "vlanrw_${pid}",    email => "vlanrw_${pid}\@example.com");
push @users, $super, $level5, $low, $rw;

grant_server_access($level5, $srv, 'R');
grant_server_access($low,    $srv, 'R');
grant_server_access($rw,     $srv, 'RW');

# level5 user: authorization level 5 (ALEVEL_VLANS)
Sauron::BackEnd::add_record('user_rights', {
  type => 2, ref => $level5, rtype => 6, rref => 0, rule => 5,
});

sub _hdr {
  my ($name) = @_;
  $t->reset_session;
  return { 'X-Remote-User' => $name };
}
my $SUPER   = _hdr("vlansuper_${pid}\@example.com");
my $LEVEL5  = _hdr("vlanlvl_${pid}\@example.com");
my $LOW     = _hdr("vlanlow_${pid}\@example.com");
my $RW      = _hdr("vlanrw_${pid}\@example.com");

my $BASE = "/api/v1/servers/srv-vlan-${pid}/vlans";
my $VLAN = "staff-${pid}";

# ========================================================================
# CREATE
# ========================================================================

subtest 'POST create VLAN (full payload)' => sub {
  $t->post_ok($BASE => $SUPER => json => {
    name        => $VLAN,
    vlanno      => 10,
    description => 'Staff network',
    comment     => 'Created by vlan.t',
    dhcp_l      => [{ dhcp => 'option domain-name "staff"', comment => 'd1' }],
    dhcp_l6     => [{ dhcp => 'option foo', comment => 'd6' }],
  })->status_is(201)->json_has('/id')->json_has('/server_id');

  my $j = $t->tx->res->json;
  is($j->{name},        $VLAN,          'name');
  is($j->{vlanno},      10,             'vlanno');
  is($j->{description}, 'Staff network','description');
  is($j->{comment},     'Created by vlan.t', 'comment');
  is_deeply($j->{dhcp_l},  [{ dhcp => 'option domain-name "staff"', comment => 'd1' }], 'dhcp_l round-trips with comment');
  is_deeply($j->{dhcp_l6}, [{ dhcp => 'option foo', comment => 'd6' }], 'dhcp_l6 round-trips with comment');
  ok($j->{cuser}, 'audit cuser present');
};

subtest 'POST create VLAN - name with a dot is addressable (relaxed placeholder)' => sub {
  my $dotted = "api.vlan.${pid}";
  $t->post_ok($BASE => $SUPER => json => { name => $dotted })->status_is(201);
  $t->get_ok("$BASE/$dotted" => $SUPER)->status_is(200)->json_is('/name' => $dotted);
  $t->delete_ok("$BASE/$dotted" => $SUPER)->status_is(204);
};

subtest 'POST create VLAN - required/charset/vlanno validation' => sub {
  $t->post_ok($BASE => $SUPER => json => { vlanno => 1 })->status_is(400);
  $t->post_ok($BASE => $SUPER => json => { name => "bad name!-${pid}" })
    ->status_is(400)->json_like('/message' => qr/match/);
  $t->post_ok($BASE => $SUPER => json => { name => "neg-${pid}", vlanno => -1 })->status_is(400);
  $t->post_ok($BASE => $SUPER => json => {
    name => "badentry-${pid}", dhcp_l => [{ dhcp => '' }],
  })->status_is(400);
};

subtest 'POST create VLAN - duplicate name returns 409' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => $VLAN })
    ->status_is(409)->json_is('/error' => 'Conflict');
};

# ========================================================================
# LIST
# ========================================================================

subtest 'GET list - summary envelope' => sub {
  $t->get_ok($BASE => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  ok(ref $j->{data} eq 'ARRAY' && exists $j->{metadata}, 'paginated envelope');
  my ($found) = grep { $_->{name} eq $VLAN } @{$j->{data}};
  ok($found, 'created VLAN in summary');
  is($found->{vlanno},      10, 'summary vlanno');
  is($found->{description}, 'Staff network', 'summary description');
  is($found->{server_id},   $srv, 'summary server_id');
  ok(!exists $found->{dhcp_l}, 'summary omits dhcp_l');
  ok(!exists $found->{cdate},  'summary omits audit fields');
};

subtest 'GET list - filters and sort' => sub {
  $t->get_ok("$BASE?name=$VLAN\$" => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  ok((grep { $_->{name} eq $VLAN } @{$j->{data}}), 'name filter matches');

  $t->get_ok("$BASE?vlanno=10" => $SUPER)->status_is(200);
  $j = $t->tx->res->json;
  ok((grep { $_->{name} eq $VLAN } @{$j->{data}}), 'vlanno filter matches');

  $t->get_ok("$BASE?description=Staff" => $SUPER)->status_is(200);
  ok((grep { $_->{name} eq $VLAN } @{$t->tx->res->json->{data}}), 'description filter matches');

  $t->get_ok("$BASE?sort=vlanno:desc" => $SUPER)->status_is(200);
  my $vlannos = [ map { $_->{vlanno} // 0 } @{$t->tx->res->json->{data}} ];
  my $sorted = [ sort { $b <=> $a } @$vlannos ];
  is_deeply($vlannos, $sorted, 'sorted by vlanno desc');

  $t->get_ok("$BASE?bogus=1" => $SUPER)->status_is(400);
  $t->get_ok("$BASE?sort=nope" => $SUPER)->status_is(400);
  $t->get_ok("$BASE?per_page=101" => $SUPER)->status_is(400);
};

# ========================================================================
# DETAIL
# ========================================================================

subtest 'GET detail - full object' => sub {
  $t->get_ok("$BASE/$VLAN" => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  for my $k (qw(dhcp_l dhcp_l6 cdate cuser mdate muser)) {
    ok(exists $j->{$k}, "detail has $k");
  }
};

subtest 'GET detail - 404 for unknown' => sub {
  $t->get_ok("$BASE/nope-${pid}" => $SUPER)->status_is(404)->json_is('/error' => 'Not Found');
};

# ========================================================================
# UPDATE
# ========================================================================

subtest 'PUT update - partial update preserves arrays' => sub {
  $t->put_ok("$BASE/$VLAN" => $SUPER => json => { comment => 'updated' })
    ->status_is(200)->json_is('/comment' => 'updated');
  my $j = $t->tx->res->json;
  is_deeply($j->{dhcp_l}, [{ dhcp => 'option domain-name "staff"', comment => 'd1' }], 'dhcp_l preserved');
};

subtest 'PUT update - arrays replace-all' => sub {
  $t->put_ok("$BASE/$VLAN" => $SUPER => json => {
    dhcp_l => [{ dhcp => 'option replaced' }],
  })->status_is(200);
  is_deeply($t->tx->res->json->{dhcp_l}, [{ dhcp => 'option replaced', comment => undef }], 'dhcp_l replaced');
};

subtest 'PUT update - rename changes the URL' => sub {
  $t->put_ok("$BASE/$VLAN" => $SUPER => json => { name => "renamed-${pid}" })
    ->status_is(200)->json_is('/name' => "renamed-${pid}");
  $t->get_ok("$BASE/$VLAN" => $SUPER)->status_is(404);
  $t->get_ok("$BASE/renamed-${pid}" => $SUPER)->status_is(200);

  # rename back for later subtests
  $t->put_ok("$BASE/renamed-${pid}" => $SUPER => json => { name => $VLAN })->status_is(200);
};

subtest 'PUT update - duplicate rename returns 409' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => "other-${pid}" })->status_is(201);
  $t->put_ok("$BASE/other-${pid}" => $SUPER => json => { name => $VLAN })->status_is(409);
  $t->delete_ok("$BASE/other-${pid}" => $SUPER)->status_is(204);
};

subtest 'PUT update - 404 for unknown' => sub {
  $t->put_ok("$BASE/nope-${pid}" => $SUPER => json => { comment => 'x' })->status_is(404);
};

# ========================================================================
# AUTHORIZATION
# ========================================================================

subtest 'read requires ALEVEL_VLANS' => sub {
  $t->get_ok($BASE => $LOW)->status_is(403);
  $t->get_ok("$BASE/$VLAN" => $LOW)->status_is(403);
};

subtest 'level >= ALEVEL_VLANS with server R can read' => sub {
  $t->get_ok($BASE => $LEVEL5)->status_is(200);
  $t->get_ok("$BASE/$VLAN" => $LEVEL5)->status_is(200)->json_is('/name' => $VLAN);
};

subtest 'writes require superuser' => sub {
  $t->post_ok($BASE => $RW => json => { name => "rw-${pid}" })
    ->status_is(403)->json_is('/error' => 'Forbidden');
  $t->put_ok("$BASE/$VLAN" => $RW => json => { comment => 'x' })->status_is(403);
  $t->delete_ok("$BASE/$VLAN" => $RW)->status_is(403);
};

# ========================================================================
# DELETE (corrected detach)
# ========================================================================

subtest 'DELETE VLAN detaches nets and vmps.fallback, removes entries' => sub {
  Sauron::BackEnd::set_muser('test');
  my $vlan_id = Sauron::BackEnd::get_vlan_by_name($srv, $VLAN);
  ok($vlan_id > 0, 'VLAN exists');

  my $net_id = Sauron::BackEnd::add_net({
    server => $srv, net => '10.99.0.0/24', netname => "vlannet-${pid}",
    name => 'VLAN detach net', subnet => 't', dummy => 'f',
  });
  ok($net_id > 0, 'net created');
  Sauron::DB::db_exec("UPDATE nets SET vlan=$vlan_id WHERE id=$net_id");

  my $vmps_id = Sauron::BackEnd::add_record('vmps', {
    server => $srv, name => "vlanvmps-${pid}", fallback => $vlan_id,
  });
  ok($vmps_id > 0, 'vmps created');

  $t->delete_ok("$BASE/$VLAN" => $SUPER)->status_is(204);
  $t->get_ok("$BASE/$VLAN" => $SUPER)->status_is(404);

  my @q;
  Sauron::DB::db_query("SELECT vlan FROM nets WHERE id=$net_id", \@q);
  is($q[0][0], -1, 'net detached (vlan=-1)');
  Sauron::DB::db_query("SELECT fallback FROM vmps WHERE id=$vmps_id", \@q);
  is($q[0][0], -1, 'vmps fallback detached (-1)');
  Sauron::DB::db_query("SELECT count(*) FROM dhcp_entries WHERE ref=$vlan_id AND type IN (6,16)", \@q);
  is($q[0][0], 0, 'dhcp entries removed');
  Sauron::DB::db_query("SELECT count(*) FROM vlans WHERE id=$vlan_id", \@q);
  is($q[0][0], 0, 'vlan row removed');

  Sauron::BackEnd::delete_net($net_id);
  Sauron::DB::db_exec("DELETE FROM vmps WHERE id=$vmps_id");
};

subtest 'DELETE VLAN - 404 for unknown' => sub {
  $t->delete_ok("$BASE/nope-${pid}" => $SUPER)->status_is(404);
};

done_testing;
