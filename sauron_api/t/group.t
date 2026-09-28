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
my (@users, @servers, @zones);
my $test_net_id;

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
  eval { Sauron::BackEnd::delete_net($test_net_id) } if $test_net_id > 0;
}

my $srv = create_test_server(name => "srv-grp-${pid}", comment => 'Group CRUD test');
my $z1  = create_test_zone(server_id => $srv, name => "zone-grp-${pid}.example.com");
push @servers, $srv;
push @zones, $z1;

Sauron::BackEnd::set_muser('test');
$test_net_id = Sauron::BackEnd::add_net({
  server  => $srv,
  net     => '10.77.0.0/24',
  netname => "grpnet-${pid}",
  name    => 'Group test net',
  subnet  => 't',
  dummy   => 'f',
});

my $super = create_test_user(username => "grpsuper_${pid}", email => "grpsuper_${pid}\@example.com", superuser => 1);
my $rw    = create_test_user(username => "grprw_${pid}",    email => "grprw_${pid}\@example.com");
my $r     = create_test_user(username => "grpr_${pid}",     email => "grpr_${pid}\@example.com");
my $gm    = create_test_user(username => "grpgm_${pid}",    email => "grpgm_${pid}\@example.com");
my $low   = create_test_user(username => "grplow_${pid}",   email => "grplow_${pid}\@example.com");
push @users, $super, $rw, $r, $gm, $low;

grant_server_access($rw,  $srv, 'RW');
grant_server_access($r,   $srv, 'R');
grant_server_access($gm,  $srv, 'RW');
grant_server_access($low, $srv, 'R');
grant_zone_access($low,   $z1,  'RW');

# grpmask: only names starting with "api-gm-${pid}" may be written.
Sauron::BackEnd::add_record('user_rights', {
  type => 2, ref => $gm, rtype => 10, rref => 0, rule => "^api-gm-${pid}",
});

sub _hdr {
  my ($name) = @_;
  $t->reset_session;
  return { 'X-Remote-User' => $name };
}
my $SUPER = _hdr("grpsuper_${pid}\@example.com");
my $RW    = _hdr("grprw_${pid}\@example.com");
my $RUSER = _hdr("grpr_${pid}\@example.com");
my $GMUSER = _hdr("grpgm_${pid}\@example.com");
my $LOW   = _hdr("grplow_${pid}\@example.com");

my $BASE  = "/api/v1/servers/srv-grp-${pid}/groups";
my $HOSTS = "/api/v1/servers/srv-grp-${pid}/zones/zone-grp-${pid}.example.com/hosts";
my $ASSIGN = "/api/v1/servers/srv-grp-${pid}/assignable-groups";

my $NORMAL = "g-normal-${pid}";

# ========================================================================
# CREATE
# ========================================================================

subtest 'POST create group (full payload)' => sub {
  $t->post_ok($BASE => $SUPER => json => {
    name      => $NORMAL,
    type      => 'normal',
    comment   => 'Created by group.t',
    dhcp_l    => [{ dhcp => 'option domain-name "example.com"', comment => 'c1' }],
    printer_l => [{ printer => 'lp01', comment => 'printer' }],
  })->status_is(201)->json_has('/id')->json_has('/server_id');

  my $j = $t->tx->res->json;
  is($j->{name},    $NORMAL,    'name');
  is($j->{type},    'normal',   'type slug on the wire');
  is($j->{comment}, 'Created by group.t', 'comment');
  is($j->{alevel},  0,          'alevel default');
  is($j->{vmps},    undef,      'vmps null by default');
  is($j->{vmps_name}, undef,    'vmps_name null');
  is_deeply($j->{dhcp_l},    [{ dhcp => 'option domain-name "example.com"', comment => 'c1' }], 'dhcp_l round-trips');
  is_deeply($j->{printer_l}, [{ printer => 'lp01', comment => 'printer' }], 'printer_l round-trips');
  is_deeply($j->{dhcp_l6},   [], 'dhcp_l6 defaults empty');
  ok($j->{cuser}, 'audit cuser present');
};

subtest 'POST create group - type defaults to normal' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => "g-default-${pid}" })
    ->status_is(201)
    ->json_is('/type' => 'normal');
};

subtest 'POST create group - duplicate name returns 409' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => $NORMAL, type => 'normal' })
    ->status_is(409)
    ->json_is('/error' => 'Conflict')
    ->json_like('/message' => qr/already exists/i);
};

subtest 'POST create group - missing name returns 400' => sub {
  $t->post_ok($BASE => $SUPER => json => { type => 'normal' })->status_is(400);
};

subtest 'POST create group - invalid type returns 400' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => "g-bad-${pid}", type => 'nope' })
    ->status_is(400);
};

subtest 'POST create group - printer_l only for normal' => sub {
  $t->post_ok($BASE => $SUPER => json => {
    name => "g-class-${pid}", type => 'dhcp_class',
    printer_l => [{ printer => 'nope' }],
  })->status_is(400)
    ->json_is('/error' => 'Bad Request')
    ->json_like('/message' => qr/printer_l/);

  # Without printer_l the same class group is created.
  $t->post_ok($BASE => $SUPER => json => {
    name => "g-class-${pid}", type => 'dhcp_class',
    dhcp_l => [{ dhcp => 'option foo bar' }],
  })->status_is(201)->json_is('/type' => 'dhcp_class');
};

subtest 'POST create group - unknown vmps returns 400' => sub {
  $t->post_ok($BASE => $SUPER => json => {
    name => "g-vmps-${pid}", type => 'normal', vmps => 999999,
  })->status_is(400)
    ->json_is('/error' => 'Bad Request')
    ->json_like('/message' => qr/VMPS/i);
};

subtest 'POST create group - negative alevel returns 400' => sub {
  $t->post_ok($BASE => $SUPER => json => {
    name => "g-alevel-${pid}", type => 'normal', alevel => -1,
  })->status_is(400);
};

# ========================================================================
# LIST
# ========================================================================

subtest 'GET list - summary envelope' => sub {
  $t->get_ok($BASE => $SUPER)->status_is(200);

  my $j = $t->tx->res->json;
  ok(ref $j->{data} eq 'ARRAY' && exists $j->{metadata}, 'paginated envelope');
  my ($found) = grep { $_->{name} eq $NORMAL } @{$j->{data}};
  ok($found, 'created group in summary');
  is($found->{type},      'normal', 'summary type');
  is($found->{comment},   'Created by group.t', 'summary comment');
  is($found->{server_id}, $srv, 'summary server_id');
  is($found->{vmps},      undef, 'summary vmps null');
  ok(!exists $found->{dhcp_l},   'summary omits dhcp_l');
  ok(!exists $found->{vmps_name},'summary omits vmps_name');
  ok(!exists $found->{cdate},    'summary omits audit fields');
};

subtest 'GET list - server-R user can list (ungated)' => sub {
  $t->get_ok($BASE => $RUSER)->status_is(200);
  my $j = $t->tx->res->json;
  ok(ref $j->{data} eq 'ARRAY', 'server-R user can list');
};

subtest 'GET list - filters' => sub {
  $t->get_ok("$BASE?name=" . $NORMAL => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  ok((grep { $_->{name} eq $NORMAL } @{$j->{data}}), 'name filter matches');
  ok(!(grep { $_->{name} eq "g-class-${pid}" } @{$j->{data}}), 'name filter excludes others');

  $t->get_ok("$BASE?type=dhcp_class" => $SUPER)->status_is(200);
  $j = $t->tx->res->json;
  ok((grep { $_->{name} eq "g-class-${pid}" } @{$j->{data}}), 'type filter matches class');
  ok(!(grep { $_->{name} eq $NORMAL } @{$j->{data}}), 'type filter excludes normal');

  $t->get_ok("$BASE?bogus=1" => $SUPER)->status_is(400);
  $t->get_ok("$BASE?sort=nope" => $SUPER)->status_is(400);
  $t->get_ok("$BASE?per_page=101" => $SUPER)->status_is(400);
  $t->get_ok("$BASE?page=0" => $SUPER)->status_is(400);
};

subtest 'GET list - sort' => sub {
  $t->get_ok("$BASE?sort=name:desc" => $SUPER)->status_is(200);
  my $names = [ map { $_->{name} } @{$t->tx->res->json->{data}} ];
  my $sorted = [ sort { $b cmp $a } @$names ];
  is_deeply($names, $sorted, 'sorted by name desc');
};

# ========================================================================
# DETAIL
# ========================================================================

subtest 'GET detail - full object' => sub {
  $t->get_ok("$BASE/$NORMAL" => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  exists $j->{$_} or fail("missing $_") for qw(dhcp_l dhcp_l6 printer_l vmps_name cdate cuser mdate muser);
  ok(ref $j->{dhcp_l} eq 'ARRAY' && ref $j->{printer_l} eq 'ARRAY', 'entry arrays present');
};

subtest 'GET detail - 404 for unknown' => sub {
  $t->get_ok("$BASE/nope-${pid}" => $SUPER)->status_is(404)->json_is('/error' => 'Not Found');
};

# ========================================================================
# UPDATE
# ========================================================================

subtest 'PUT update group - partial update preserves arrays' => sub {
  $t->put_ok("$BASE/$NORMAL" => $SUPER => json => { comment => 'updated' })
    ->status_is(200)
    ->json_is('/comment' => 'updated')
    ->json_is('/name'    => $NORMAL);
  my $j = $t->tx->res->json;
  is_deeply($j->{dhcp_l}, [{ dhcp => 'option domain-name "example.com"', comment => 'c1' }], 'dhcp_l preserved');
  is_deeply($j->{printer_l}, [{ printer => 'lp01', comment => 'printer' }], 'printer_l preserved');
};

subtest 'PUT update group - arrays replace-all' => sub {
  $t->put_ok("$BASE/$NORMAL" => $SUPER => json => {
    dhcp_l => [{ dhcp => 'option replaced' }],
  })->status_is(200);
  my $j = $t->tx->res->json;
  is_deeply($j->{dhcp_l}, [{ dhcp => 'option replaced', comment => undef }], 'dhcp_l replaced');
};

subtest 'PUT update group - rename changes the URL' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => "g-rename-${pid}", type => 'normal' })
    ->status_is(201);
  $t->put_ok("$BASE/g-rename-${pid}" => $SUPER => json => { name => "g-renamed-${pid}" })
    ->status_is(200)->json_is('/name' => "g-renamed-${pid}");
  $t->get_ok("$BASE/g-rename-${pid}"  => $SUPER)->status_is(404);
  $t->get_ok("$BASE/g-renamed-${pid}" => $SUPER)->status_is(200);
};

subtest 'PUT update group - duplicate rename returns 409' => sub {
  $t->put_ok("$BASE/g-renamed-${pid}" => $SUPER => json => { name => "g-class-${pid}" })
    ->status_is(409);
};

subtest 'PUT update group - type is mutable' => sub {
  $t->put_ok("$BASE/g-renamed-${pid}" => $SUPER => json => { type => 'dynamic_pool' })
    ->status_is(200)->json_is('/type' => 'dynamic_pool');
};

subtest 'PUT update group - 404 for unknown' => sub {
  $t->put_ok("$BASE/nope-${pid}" => $SUPER => json => { comment => 'x' })->status_is(404);
};

# ========================================================================
# DELETE
# ========================================================================

subtest 'DELETE group - detaches member hosts by default' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => "g-del-${pid}", type => 'normal' })
    ->status_is(201);
  my $gid = Sauron::BackEnd::get_group_by_name($srv, "g-del-${pid}");
  ok($gid > 0, 'group created');

  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "h-del-${pid}", type => 1,
    ip => [[0, '10.77.0.10', 't', 't', 2]],
  });
  ok($hid > 0, 'host created');
  Sauron::DB::db_exec("UPDATE hosts SET grp=$gid WHERE id=$hid");
  Sauron::DB::db_exec("INSERT INTO group_entries(host,grp) VALUES($hid,$gid)");

  $t->delete_ok("$BASE/g-del-${pid}" => $SUPER)->status_is(204);
  $t->get_ok("$BASE/g-del-${pid}" => $SUPER)->status_is(404);

  my @q;
  Sauron::DB::db_query("SELECT grp FROM hosts WHERE id=$hid", \@q);
  is($q[0][0], -1, 'host base group detached');
  my @e;
  Sauron::DB::db_query("SELECT count(*) FROM group_entries WHERE host=$hid AND grp=$gid", \@e);
  is($e[0][0], 0, 'subgroup rows removed');
};

subtest 'DELETE group - reassign members' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => "g-del-a-${pid}", type => 'normal' })->status_is(201);
  $t->post_ok($BASE => $SUPER => json => { name => "g-del-b-${pid}", type => 'normal' })->status_is(201);
  my $a = Sauron::BackEnd::get_group_by_name($srv, "g-del-a-${pid}");
  my $b = Sauron::BackEnd::get_group_by_name($srv, "g-del-b-${pid}");

  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "h-rs-${pid}", type => 1,
    ip => [[0, '10.77.0.11', 't', 't', 2]],
  });
  Sauron::DB::db_exec("UPDATE hosts SET grp=$a WHERE id=$hid");

  $t->delete_ok("$BASE/g-del-a-${pid}?reassign_to=g-del-b-${pid}" => $SUPER)->status_is(204);

  my @q;
  Sauron::DB::db_query("SELECT grp FROM hosts WHERE id=$hid", \@q);
  is($q[0][0], $b, 'host moved to reassign target');
};

subtest 'DELETE group - self reassign 400, unknown target 404' => sub {
  $t->delete_ok("$BASE/g-del-b-${pid}?reassign_to=g-del-b-${pid}" => $SUPER)
    ->status_is(400)->json_like('/message' => qr/being deleted/i);
  $t->delete_ok("$BASE/g-del-b-${pid}?reassign_to=nope-${pid}" => $SUPER)
    ->status_is(404);
};

# ========================================================================
# ASSIGNABLE PICKER
# ========================================================================

subtest 'GET assignable-groups - role filters by type' => sub {
  $t->get_ok("$ASSIGN?role=base" => $SUPER)->status_is(200);
  my $base = $t->tx->res->json;
  ok(ref $base eq 'ARRAY', 'bare array');
  ok((grep { $_->{name} eq "g-class-${pid}" } @$base) ? 0 : 1, 'base excludes dhcp_class');
  ok((grep { $_->{name} eq $NORMAL } @$base), 'base includes normal');

  $t->get_ok("$ASSIGN?role=subgroup" => $SUPER)->status_is(200);
  my $sub = $t->tx->res->json;
  ok((grep { $_->{name} eq "g-class-${pid}" } @$sub), 'subgroup includes dhcp_class');

  $t->get_ok("$ASSIGN?role=bogus" => $SUPER)->status_is(400);
};

subtest 'GET assignable-groups - alevel ceiling' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => "g-high-${pid}", type => 'normal', alevel => 5 })
    ->status_is(201);

  $t->get_ok("$ASSIGN?role=base" => $LOW)->status_is(200);
  my $low = $t->tx->res->json;
  ok((grep { $_->{name} eq "g-high-${pid}" } @$low) ? 0 : 1, 'low-alevel user cannot see high group');

  $t->get_ok("$ASSIGN?role=base" => $SUPER)->status_is(200);
  ok((grep { $_->{name} eq "g-high-${pid}" } @{$t->tx->res->json}), 'superuser sees high group');
};

# ========================================================================
# AUTHORIZATION
# ========================================================================

subtest 'POST create group - server RW without grpmask is denied' => sub {
  $t->post_ok($BASE => $RW => json => { name => "rw-${pid}", type => 'normal' })
    ->status_is(403)->json_is('/error' => 'Forbidden');
};

subtest 'POST create group - server R is denied' => sub {
  $t->post_ok($BASE => $RUSER => json => { name => "r-${pid}", type => 'normal' })
    ->status_is(403);
};

subtest 'POST create group - grpmask match allows, mismatch denies' => sub {
  $t->post_ok($BASE => $GMUSER => json => { name => "api-gm-${pid}-ok", type => 'normal' })
    ->status_is(201);
  $t->post_ok($BASE => $GMUSER => json => { name => "not-allowed-${pid}", type => 'normal' })
    ->status_is(403)->json_like('/message' => qr/not authorized/i);
};

subtest 'DELETE group - grpmask enforced' => sub {
  $t->delete_ok("$BASE/not-allowed-${pid}" => $GMUSER)->status_is(404);
  $t->delete_ok("$BASE/$NORMAL" => $GMUSER)->status_is(403);
};

subtest 'GET group - server R can read' => sub {
  $t->get_ok("$BASE/$NORMAL" => $RUSER)->status_is(200);
  $t->get_ok($BASE => $RUSER)->status_is(200);
};

# ========================================================================
# HOST WRITE ENFORCEMENT (ADR 0008)
# ========================================================================

subtest 'host create - unknown base group is rejected' => sub {
  $t->post_ok($HOSTS => $SUPER => json => {
    hostname => "h-unknown-${pid}", type => 'host',
    grp => 999999, ips => [{ ip => '10.77.0.20' }],
  })->status_is(400)->json_like('/message' => qr/Unknown group/i);
};

subtest 'host create - dhcp_class cannot be a base group' => sub {
  my $class = Sauron::BackEnd::get_group_by_name($srv, "g-class-${pid}");
  $t->post_ok($HOSTS => $SUPER => json => {
    hostname => "h-class-${pid}", type => 'host',
    grp => $class, ips => [{ ip => '10.77.0.21' }],
  })->status_is(400)->json_like('/message' => qr/not assignable as a base group/i);
};

subtest 'host create - grp rejected on non host/printer type' => sub {
  my $normal = Sauron::BackEnd::get_group_by_name($srv, $NORMAL);
  $t->post_ok($HOSTS => $SUPER => json => {
    hostname => "h-deleg-${pid}", type => 'delegation', grp => $normal,
  })->status_is(400)->json_like('/message' => qr/only valid for host types/i);
};

subtest 'host create - valid base group + dhcp_class subgroup' => sub {
  my $normal = Sauron::BackEnd::get_group_by_name($srv, $NORMAL);
  my $class  = Sauron::BackEnd::get_group_by_name($srv, "g-class-${pid}");
  $t->post_ok($HOSTS => $SUPER => json => {
    hostname => "h-ok-${pid}", type => 'host', grp => $normal,
    subgroups => [{ grp => $class }],
    ips => [{ ip => '10.77.0.22' }],
  })->status_is(201);

  my $j = $t->tx->res->json;
  is($j->{grp}, $normal, 'base group stored');
  is_deeply($j->{subgroups}, [{ grp => $class }], 'subgroup stored');
};

subtest 'host create - base group above caller alevel is rejected' => sub {
  my $high = Sauron::BackEnd::get_group_by_name($srv, "g-high-${pid}");
  $t->post_ok($HOSTS => $LOW => json => {
    hostname => "h-high-${pid}", type => 'host',
    grp => $high, ips => [{ ip => '10.77.0.23' }],
  })->status_is(400)->json_like('/message' => qr/above your authorization level/i);

  my $normal = Sauron::BackEnd::get_group_by_name($srv, $NORMAL);
  $t->post_ok($HOSTS => $LOW => json => {
    hostname => "h-low-${pid}", type => 'host',
    grp => $normal, ips => [{ ip => '10.77.0.24' }],
  })->status_is(201);
};

done_testing;
