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
}

my $srv = create_test_server(name => "srv-host-${pid}", comment => 'Host CRUD test');
my $z1  = create_test_zone(server_id => $srv, name => "zone-host1-${pid}.example.com");
push @servers, $srv;
push @zones, $z1;

my $super = create_test_user(username => "hostsuper_${pid}", email => "hostsuper_${pid}\@example.com", superuser => 1);
my $user  = create_test_user(username => "hostuser_${pid}",  email => "hostuser_${pid}\@example.com");
push @users, $super, $user;
grant_zone_access($user, $z1, 'RW');

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
  $t->post_ok($URL => $RHF => json => { hostname => "yesrhf-${pid}", type => 1, dept => 'Engineering' })
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
    zone => $z1, domain => "updrhf-${pid}", type => 1, dept => 'Engineering'
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
    zone => $z1, domain => "skiprhf-${pid}", type => 1, dept => 'Engineering'
  });
  ok($hid > 0, "Created host id=$hid");

  $t->put_ok("$URL/skiprhf-${pid}" => $RHF => json => { comment => 'not touching dept' })
    ->status_is(200)
    ->json_is('/comment' => 'not touching dept')
    ->json_is('/dept'    => 'Engineering');

  Sauron::BackEnd::delete_host($hid);
};

subtest 'Superuser bypasses RHF' => sub {
  $t->post_ok($URL => $SUPER => json => { hostname => "suprhf-${pid}", type => 1 })
    ->status_is(201);

  my $id = $t->tx->res->json->{id};
  Sauron::BackEnd::delete_host($id) if $id > 0;
};

# ========================================================================
# Success paths
# ========================================================================

subtest 'POST create host without IPs' => sub {
  $t->post_ok($URL => $USER => json => { hostname => "minimal-${pid}", type => 1 })
    ->status_is(201)
    ->json_is('/domain'  => "minimal-${pid}")
    ->json_is('/type'    => 1)
    ->json_is('/ips'     => [])
    ->json_is('/zone_id' => $z1)
    ->json_is('/server_id' => $srv)
    ->json_has('/id')
    ->json_has('/cdate');

  # Cleanup
  my $id = $t->tx->res->json->{id};
  Sauron::BackEnd::delete_host($id);
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
  my $hid = Sauron::BackEnd::add_host({ zone => $z1, domain => "read-${pid}", type => 1 });
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
  my $hid = Sauron::BackEnd::add_host({ zone => $z1, domain => "upd-${pid}", type => 1, ttl => 1800 });
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
  $t->post_ok($URL => $USER => json => { hostname => "del-${pid}", type => 1 })
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

done_testing();
