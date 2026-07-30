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
  grant_rhf
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

my $srv = create_test_server(name => "srv-host-${pid}", comment => 'Host CRUD test');
my $z1  = create_test_zone(server_id => $srv, name => "zone-host1-${pid}.example.com");
my $z2  = create_test_zone(server_id => $srv, name => "zone-host2-${pid}.example.com");
push @servers, $srv;
push @zones, $z1, $z2;

# Create a test network for copy-IP auto-assignment tests
Sauron::BackEnd::set_muser('test');
$test_net_id = Sauron::BackEnd::add_net({
  server   => $srv,
  net      => '10.0.0.0/24',
  netname  => "testnet-${pid}",
  name     => 'Test network for host tests',
  subnet   => 't',
  dummy    => 'f',
});

my $super = create_test_user(username => "hostsuper_${pid}", email => "hostsuper_${pid}\@example.com", superuser => 1);
my $user  = create_test_user(username => "hostuser_${pid}",  email => "hostuser_${pid}\@example.com");
my $nozone_user = create_test_user(username => "nocopy_${pid}", email => "nocopy_${pid}\@example.com");
push @users, $super, $user, $nozone_user;
grant_zone_access($user, $z1, 'RW');
grant_zone_access($user, $z2, 'RW');

sub _as_super {
  $t->reset_session;
  return { 'X-Remote-User' => "hostsuper_${pid}\@example.com" };
}
sub _as_user {
  $t->reset_session;
  return { 'X-Remote-User' => "hostuser_${pid}\@example.com" };
}
my $SUPER = _as_super();
my $USER  = _as_user();

sub _as_nozone {
  $t->reset_session;
  return { 'X-Remote-User' => "nocopy_${pid}\@example.com" };
}
my $NOZONE = _as_nozone();

my $URL = "/api/v1/servers/srv-host-${pid}/zones/zone-host1-${pid}.example.com/hosts";

# ========================================================================
# Error paths
# ========================================================================

subtest 'GET non-existent host' => sub {
  $t->get_ok("$URL/nonexistent" => $SUPER)
    ->status_is(404)
    ->json_is('/error' => 'Not Found');
};

subtest 'GET host on non-existent zone' => sub {
  $t->get_ok("/api/v1/servers/srv-host-${pid}/zones/nosuchzone/hosts/foo" => $SUPER)
    ->status_is(404)
    ->json_is('/error' => 'Not Found');
};

subtest 'POST without hostname' => sub {
  $t->post_ok($URL => $SUPER => json => { type => 1 })
    ->status_is(400)
    ->json_has('/errors');
};

subtest 'POST with invalid field for host type' => sub {
  $t->post_ok($URL => $SUPER => json => { hostname => "bad-${pid}", type => 6, mx_l => [{pri => 10, mx => 'mail.example.com'}] })
    ->status_is(400)
    ->json_is('/error' => 'Bad Request')
    ->json_like('/message' => qr/not valid for host type/);
};

subtest 'POST duplicate host' => sub {
  $t->post_ok($URL => $SUPER => json => { hostname => "dup-${pid}", type => 1, ips => [{ ip => '10.0.0.1' }] })
    ->status_is(201);
  $t->post_ok($URL => $SUPER => json => { hostname => "dup-${pid}", type => 1 })
    ->status_is(409)
    ->json_is('/error' => 'Conflict');

  # Cleanup
  my $dup_id = Sauron::BackEnd::get_host_id($z1, "dup-${pid}");
  Sauron::BackEnd::delete_host($dup_id) if $dup_id > 0;
};

# RHF user with `dept` required
my $rhf_user = create_test_user(username => "hostrhf_${pid}", email => "hostrhf_${pid}\@example.com");
push @users, $rhf_user;
grant_zone_access($rhf_user, $z1, 'RW');
grant_rhf($rhf_user, 'dept', 0);  # 0 = required
sub _as_rhf {
  $t->reset_session;
  return { 'X-Remote-User' => "hostrhf_${pid}\@example.com" };
}
my $RHF = _as_rhf();

subtest 'POST create host fails without required field (RHF)' => sub {
  $t->post_ok($URL => $RHF => json => { hostname => "norhf-${pid}", type => 1 })
    ->status_is(400)
    ->json_is('/error' => 'Bad Request')
    ->json_like('/message' => qr/dept/);
};

subtest 'POST create host succeeds with required field (RHF)' => sub {
  $t->post_ok($URL => $RHF => json => {
    hostname => "yesrhf-${pid}", type => 1, dept => 'Engineering',
    ips => [{ ip => '10.0.0.150' }],
  })
    ->status_is(201)
    ->json_is('/domain' => "yesrhf-${pid}")
    ->json_is('/dept'   => 'Engineering');

  my $id = $t->tx->res->json->{id};
  Sauron::BackEnd::delete_host($id) if $id > 0;
};

subtest 'POST create host succeeds with whitespace-only field (RHF)' => sub {
  $t->post_ok($URL => $RHF => json => { hostname => "wsrhf-${pid}", type => 1, dept => '  ' })
    ->status_is(400)
    ->json_is('/error' => 'Bad Request')
    ->json_like('/message' => qr/dept/);
};

subtest 'PUT update host rejects clearing required field (RHF)' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "updrhf-${pid}", type => 1, dept => 'Engineering',
    ip => [[0, '10.0.0.151', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->put_ok("$URL/updrhf-${pid}" => $RHF => json => { dept => '' })
    ->status_is(400)
    ->json_is('/error' => 'Bad Request');

  Sauron::BackEnd::delete_host($hid);
};

subtest 'PUT update host allows omitting required field (RHF)' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "skiprhf-${pid}", type => 1, dept => 'Engineering',
    ip => [[0, '10.0.0.152', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->put_ok("$URL/skiprhf-${pid}" => $RHF => json => { comment => 'not touching dept' })
    ->status_is(200)
    ->json_is('/comment' => 'not touching dept')
    ->json_is('/dept'    => 'Engineering');

  Sauron::BackEnd::delete_host($hid);
};

subtest 'Superuser bypasses RHF' => sub {
  $t->post_ok($URL => $SUPER => json => {
    hostname => "suprhf-${pid}", type => 1,
    ips => [{ ip => '10.0.0.153' }],
  })
    ->status_is(201);

  my $id = $t->tx->res->json->{id};
  Sauron::BackEnd::delete_host($id) if $id > 0;
};

# ========================================================================
# Success paths
# ========================================================================

subtest 'POST create host without IPs is rejected' => sub {
  # BackEnd requires at least one IP for type 1 (host_required_data_error);
  # the API maps that to a 400, not a 500.
  $t->post_ok($URL => $USER => json => { hostname => "minimal-${pid}", type => 1 })
    ->status_is(400)
    ->json_is('/error' => 'Bad Request')
    ->json_like('/message' => qr/requires at least one IP address/);

  $t->post_ok($URL => $USER => json => { hostname => "minimal-${pid}", type => 1, ips => [] })
    ->status_is(400)
    ->json_is('/error' => 'Bad Request');
};

subtest 'POST create host with IPs' => sub {
  $t->post_ok($URL => $USER => json => {
    hostname => "full-${pid}",
    type     => 1,
    ips      => [{ ip => '10.0.0.10' }, { ip => '10.0.0.11' }],
    ttl      => 3600,
    comment  => 'test host with IPs',
  })
    ->status_is(201)
    ->json_is('/domain'  => "full-${pid}")
    ->json_is('/ips/0/ip' => '10.0.0.10')
    ->json_is('/ips/0/reverse' => JSON::PP::true)
    ->json_is('/ips/0/forward' => JSON::PP::true)
    ->json_is('/ips/1/ip' => '10.0.0.11')
    ->json_is('/ttl'     => 3600)
    ->json_is('/comment' => 'test host with IPs');

  # Cleanup
  my $id = $t->tx->res->json->{id};
  Sauron::BackEnd::delete_host($id);
};

subtest 'POST create host with scalar fields' => sub {
  $t->post_ok($URL => $USER => json => {
    hostname => "scalar-${pid}",
    type     => 1,
    ips      => [{ ip => '10.0.0.20' }],
    ttl      => 7200,
    class    => 'IN',
    location => 'Building A',
    dept     => 'IT',
    info     => 'test scalar fields',
    ether    => '001122334455',
  })
    ->status_is(201)
    ->json_is('/domain'   => "scalar-${pid}")
    ->json_is('/ttl'      => 7200)
    ->json_is('/class'    => 'IN')
    ->json_is('/location' => 'Building A')
    ->json_is('/dept'     => 'IT')
    ->json_is('/info'     => 'test scalar fields');

  # Cleanup
  my $id = $t->tx->res->json->{id};
  Sauron::BackEnd::delete_host($id);
};

subtest 'GET host' => sub {
  # Create via BackEnd for clean test
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "read-${pid}", type => 1,
    ip => [[0, '10.0.0.154', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->get_ok("$URL/read-${pid}" => $SUPER)
    ->status_is(200)
    ->json_is('/domain'  => "read-${pid}")
    ->json_is('/type'    => 1)
    ->json_is('/zone_id' => $z1)
    ->json_is('/server_id' => $srv)
    ->json_like('/fqdn' => qr/read-${pid}/);

  Sauron::BackEnd::delete_host($hid);
};

subtest 'GET host with IPs' => sub {
  # Create via BackEnd with IPs
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone   => $z1,
    domain => "readip-${pid}",
    type   => 1,
    ip     => [[0, '10.0.0.30', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->get_ok("$URL/readip-${pid}" => $SUPER)
    ->status_is(200)
    ->json_is('/domain' => "readip-${pid}")
    ->json_is('/ips/0/ip' => '10.0.0.30')
    ->json_is('/ips/0/reverse' => JSON::PP::true)
    ->json_is('/ips/0/forward' => JSON::PP::true);

  Sauron::BackEnd::delete_host($hid);
};

subtest 'PUT update host' => sub {
  # Create via BackEnd
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "upd-${pid}", type => 1, ttl => 1800,
    ip => [[0, '10.0.0.155', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->put_ok("$URL/upd-${pid}" => $USER => json => {
    ttl      => 9999,
    comment  => 'updated by test',
    location => 'New Location',
    ips      => [{ ip => '10.0.0.100' }],
  })
    ->status_is(200)
    ->json_is('/domain'   => "upd-${pid}")
    ->json_is('/ttl'      => 9999)
    ->json_is('/comment'  => 'updated by test')
    ->json_is('/location' => 'New Location')
    ->json_is('/ips/0/ip' => '10.0.0.100')
    ->json_is('/ips/0/reverse' => JSON::PP::true)
    ->json_is('/ips/0/forward' => JSON::PP::true);

  Sauron::BackEnd::delete_host($hid);
};

subtest 'PUT update host ip flags' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "flags-${pid}", type => 1,
    ip => [[0, '10.0.0.200', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->put_ok("$URL/flags-${pid}" => $USER => json => {
    ips => [{ ip => '10.0.0.200', reverse => JSON::PP::false, forward => JSON::PP::true }],
  })
    ->status_is(200)
    ->json_is('/ips/0/ip' => '10.0.0.200')
    ->json_is('/ips/0/reverse' => JSON::PP::false)
    ->json_is('/ips/0/forward' => JSON::PP::true);

  Sauron::BackEnd::delete_host($hid);
};

subtest 'PUT update non-existent host' => sub {
  $t->put_ok("$URL/nosuchhost" => $SUPER => json => { ttl => 999 })
    ->status_is(404)
    ->json_is('/error' => 'Not Found');
};

subtest 'DELETE host' => sub {
  # Create via API
  $t->post_ok($URL => $USER => json => {
    hostname => "del-${pid}", type => 1,
    ips => [{ ip => '10.0.0.156' }],
  })
    ->status_is(201);
  my $del_id = $t->tx->res->json->{id};

  $t->delete_ok("$URL/del-${pid}" => $USER)
    ->status_is(204);

  # Verify deletion
  $t->get_ok("$URL/del-${pid}" => $SUPER)
    ->status_is(404);
};

subtest 'DELETE non-existent host' => sub {
  $t->delete_ok("$URL/nonexistent" => $SUPER)
    ->status_is(404)
    ->json_is('/error' => 'Not Found');
};

# ========================================================================
# Copy tests
# ========================================================================

subtest 'POST copy non-existent host' => sub {
  $t->post_ok("$URL/nosuchhost/copies" => $SUPER => json => {})
    ->status_is(404)
    ->json_is('/error' => 'Not Found');
};

subtest 'POST copy without zone RW permission' => sub {
  # Create source host first
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "copsrc-${pid}", type => 1,
    ip => [[0, '10.0.0.77', 't', 't', 2]],
  });
  ok($hid > 0, "Created source host id=$hid");

  # A user with no zone access tries to copy
  $t->post_ok("$URL/copsrc-${pid}/copies" => $NOZONE => json => {})
    ->status_is(403);

  Sauron::BackEnd::delete_host($hid);
};

subtest 'POST copy empty body' => sub {
  # Create source host with fields to copy
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "src1-${pid}", type => 1,
    ttl => 3600, comment => 'copy me',
    info => 'original info',
    ip => [[0, '10.0.0.80', 't', 't', 2]],
  });
  ok($hid > 0, "Created source host id=$hid");

  $t->post_ok("$URL/src1-${pid}/copies" => $SUPER => json => {})
    ->status_is(201)
    ->json_is('/type' => 1)
    ->json_is('/comment' => 'copy me')
    ->json_is('/info' => 'original info')
    ->json_is('/ether' => undef)
    ->json_is('/duid' => undef)
    ->json_is('/iaid' => undef)
    ->json_is('/serial' => undef)
    ->json_is('/asset_id' => undef)
    ->json_has('/id')
    ->json_has('/ips');

  my $new_id = $t->tx->res->json->{id};
  my $new_domain = $t->tx->res->json->{domain};
  isnt($new_domain, "src1-${pid}", 'copy has different hostname');
  like($new_domain, qr/src1/, 'hostname derived from source');

  # Cleanup
  Sauron::BackEnd::delete_host($hid);
  Sauron::BackEnd::delete_host($new_id);
};

subtest 'POST copy with explicit hostname' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "src2-${pid}", type => 1,
    ttl => 3600,
    ip => [[0, '10.0.0.81', 't', 't', 2]],
  });
  ok($hid > 0, "Created source host id=$hid");

  $t->post_ok("$URL/src2-${pid}/copies" => $SUPER => json => {
    hostname => "explicit-copy-${pid}",
  })
    ->status_is(201)
    ->json_is('/domain' => "explicit-copy-${pid}");

  my $new_id = $t->tx->res->json->{id};
  Sauron::BackEnd::delete_host($hid);
  Sauron::BackEnd::delete_host($new_id);
};

subtest 'POST copy with field overrides' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "src3-${pid}", type => 1,
    ttl => 3600, location => 'Old Location', comment => 'old comment',
    ip => [[0, '10.0.0.82', 't', 't', 2]],
  });
  ok($hid > 0, "Created source host id=$hid");

  $t->post_ok("$URL/src3-${pid}/copies" => $SUPER => json => {
    ttl      => 7200,
    comment  => 'overridden',
    location => 'New Location',
  })
    ->status_is(201)
    ->json_is('/ttl'      => 7200)
    ->json_is('/comment'  => 'overridden')
    ->json_is('/location' => 'New Location');

  my $new_id = $t->tx->res->json->{id};
  Sauron::BackEnd::delete_host($hid);
  Sauron::BackEnd::delete_host($new_id);
};

subtest 'POST copy with type override drops invalid source arrays' => sub {
  # Source type 1 with MX + TXT records
  $t->post_ok($URL => $SUPER => json => {
    hostname => "ovrsrc-${pid}", type => 1,
    ips   => [{ ip => '10.0.0.160' }],
    mx_l  => [{ pri => 10, mx => 'mail.example.com.' }],
    txt_l => [{ txt => 'source txt' }],
  })->status_is(201);
  my $src_id = $t->tx->res->json->{id};

  # Override type 1 -> 3 (plain MX): MX + TXT kept (both valid for type 3),
  # but no IP auto-assigned (type 3 holds no IPs)
  $t->post_ok("$URL/ovrsrc-${pid}/copies" => $SUPER => json => {
    hostname => "ovrmx-${pid}", type => 3,
  })
    ->status_is(201)
    ->json_is('/type'  => 3)
    ->json_is('/ips'   => [])
    ->json_is('/mx_l/0/mx' => 'mail.example.com.')
    ->json_is('/txt_l/0/txt' => 'source txt');
  my $mx_id = $t->tx->res->json->{id};

  # Override type 1 -> 9 (DHCP only): MX/TXT dropped (invalid for type 9)
  $t->post_ok("$URL/ovrsrc-${pid}/copies" => $SUPER => json => {
    hostname => "ovrdhcp-${pid}", type => 9, ips => [{ ip => '10.0.0.161' }],
  })
    ->status_is(201)
    ->json_is('/type'  => 9)
    ->json_is('/mx_l'  => undef)
    ->json_is('/txt_l' => undef);
  my $dhcp_id = $t->tx->res->json->{id};

  # Same-type copy (empty body): source arrays inherited, IP auto-assigned
  $t->post_ok("$URL/ovrsrc-${pid}/copies" => $SUPER => json => {})
    ->status_is(201)
    ->json_is('/type' => 1)
    ->json_is('/mx_l/0/mx' => 'mail.example.com.')
    ->json_is('/txt_l/0/txt' => 'source txt')
    ->json_has('/ips/0/ip');
  my $same_id = $t->tx->res->json->{id};

  Sauron::BackEnd::delete_host($same_id);
  Sauron::BackEnd::delete_host($dhcp_id);
  Sauron::BackEnd::delete_host($mx_id);
  Sauron::BackEnd::delete_host($src_id);
};

# ========================================================================
# Move tests
# ========================================================================

subtest 'POST move IP (explicit)' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "mvip-${pid}", type => 1,
    ip => [[0, '10.0.0.50', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->post_ok("$URL/mvip-${pid}/move" => $USER => json => { ip => '10.0.0.60' })
    ->status_is(200)
    ->json_is('/ips/0/ip' => '10.0.0.60');

  Sauron::BackEnd::delete_host($hid);
};

subtest 'POST move IP (net auto-assign)' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "mvnet-${pid}", type => 1,
    ip => [[0, '10.0.0.51', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->post_ok("$URL/mvnet-${pid}/move" => $USER => json => { net => '10.0.0.0/24' })
    ->status_is(200)
    ->json_has('/ips/0/ip');

  Sauron::BackEnd::delete_host($hid);
};

subtest 'POST move IP conflict' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "mvcon-${pid}", type => 1,
    ip => [[0, '10.0.0.52', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");
  my $hid2 = Sauron::BackEnd::add_host({
    zone => $z1, domain => "mvconother-${pid}", type => 1,
    ip => [[0, '10.0.0.70', 't', 't', 2]],
  });

  $t->post_ok("$URL/mvcon-${pid}/move" => $USER => json => { ip => '10.0.0.70' })
    ->status_is(409);

  Sauron::BackEnd::delete_host($hid);
  Sauron::BackEnd::delete_host($hid2);
};

subtest 'POST move zone' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "mvzone-${pid}", type => 1,
    ip => [[0, '10.0.0.53', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->post_ok("$URL/mvzone-${pid}/move" => $USER => json => { zone => "zone-host2-${pid}.example.com" })
    ->status_is(200)
    ->json_is('/domain' => "mvzone-${pid}")
    ->json_is('/zone_id' => $z2);

  # Verify MX cleared
  my %h;
  Sauron::BackEnd::get_host($hid, \%h);
  is($h{mx}, -1, 'MX template cleared on zone move');

  Sauron::BackEnd::delete_host($hid);
};

subtest 'POST move to same zone' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "mvsame-${pid}", type => 1,
    ip => [[0, '10.0.0.54', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->post_ok("$URL/mvsame-${pid}/move" => $USER => json => { zone => "zone-host1-${pid}.example.com" })
    ->status_is(400);

  Sauron::BackEnd::delete_host($hid);
};

subtest 'POST move zone with hostname conflict in target' => sub {
  Sauron::BackEnd::set_muser('test');
  # Host in source zone
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "mvconfzone-${pid}", type => 1,
    ip => [[0, '10.0.0.58', 't', 't', 2]],
  });
  ok($hid > 0, "Created source host id=$hid");
  # Conflicting host with same domain in target zone
  my $hid2 = Sauron::BackEnd::add_host({
    zone => $z2, domain => "mvconfzone-${pid}", type => 1,
    ip => [[0, '10.0.0.59', 't', 't', 2]],
  });
  ok($hid2 > 0, "Created conflicting host id=$hid2");

  $t->post_ok("$URL/mvconfzone-${pid}/move" => $USER => json => { zone => "zone-host2-${pid}.example.com" })
    ->status_is(409)
    ->json_is('/error' => 'Conflict');

  Sauron::BackEnd::delete_host($hid);
  Sauron::BackEnd::delete_host($hid2);
};

subtest 'POST move empty body' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "mvempty-${pid}", type => 1,
    ip => [[0, '10.0.0.55', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->post_ok("$URL/mvempty-${pid}/move" => $USER => json => {})
    ->status_is(400);

  Sauron::BackEnd::delete_host($hid);
};

subtest 'POST move with both ip and zone' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "mvboth-${pid}", type => 1,
    ip => [[0, '10.0.0.56', 't', 't', 2]],
  });
  ok($hid > 0, "Created host id=$hid");

  $t->post_ok("$URL/mvboth-${pid}/move" => $USER => json => { ip => '10.0.0.90', zone => "zone-host2-${pid}.example.com" })
    ->status_is(400);

  Sauron::BackEnd::delete_host($hid);
};

subtest 'POST move non-type-1 host' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "mvtype-${pid}", type => 3, mx => 1,
  });
  ok($hid > 0, "Created host id=$hid");

  $t->post_ok("$URL/mvtype-${pid}/move" => $USER => json => { ip => '10.0.0.91' })
    ->status_is(400);

  Sauron::BackEnd::delete_host($hid);
};

subtest 'POST copy with device-field overrides' => sub {
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "srcdev-${pid}", type => 1,
    ether => 'AABBCCDDEEFF', serial => 'SRC-SERIAL',
    ip => [[0, '10.0.0.83', 't', 't', 2]],
  });
  ok($hid > 0, "Created source host id=$hid");

  # Empty body: device fields must NOT be copied from source
  $t->post_ok("$URL/srcdev-${pid}/copies" => $SUPER => json => {})
    ->status_is(201)
    ->json_is('/ether' => undef)
    ->json_is('/serial' => undef);
  my $cid1 = $t->tx->res->json->{id};
  Sauron::BackEnd::delete_host($cid1) if $cid1;

  # Explicit overrides: device fields accepted
  $t->post_ok("$URL/srcdev-${pid}/copies" => $SUPER => json => {
    hostname => "devcopy-${pid}",
    ether    => '001122334455',
    duid     => '00:01:00:01:aa',
    serial   => 'NEW-SERIAL',
    asset_id => 'ASSET-42',
  })
    ->status_is(201)
    ->json_is('/ether'    => '001122334455')
    ->json_is('/duid'     => '00:01:00:01:aa')
    ->json_is('/serial'   => 'NEW-SERIAL')
    ->json_is('/asset_id' => 'ASSET-42');

  my $cid2 = $t->tx->res->json->{id};
  Sauron::BackEnd::delete_host($cid2) if $cid2;
  Sauron::BackEnd::delete_host($hid);
};

subtest 'POST copy enforces RHF on merged record' => sub {
  # Source has no dept (created via BackEnd, bypassing RHF)
  Sauron::BackEnd::set_muser('test');
  my $hid = Sauron::BackEnd::add_host({
    zone => $z1, domain => "rhfsrc-${pid}", type => 1,
    ip => [[0, '10.0.0.84', 't', 't', 2]],
  });
  ok($hid > 0, "Created source host id=$hid");

  # RHF user copies without dept -> rejected
  $t->post_ok("$URL/rhfsrc-${pid}/copies" => $RHF => json => {})
    ->status_is(400)
    ->json_is('/error' => 'Bad Request')
    ->json_like('/message' => qr/dept/);

  # RHF user copies with dept override -> accepted
  $t->post_ok("$URL/rhfsrc-${pid}/copies" => $RHF => json => { dept => 'Engineering' })
    ->status_is(201)
    ->json_is('/dept' => 'Engineering');

  my $cid = $t->tx->res->json->{id};
  Sauron::BackEnd::delete_host($cid) if $cid;
  Sauron::BackEnd::delete_host($hid);
};

done_testing();
