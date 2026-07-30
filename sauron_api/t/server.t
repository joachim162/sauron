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
my (@users, @servers);

END {
  for my $uid (@users) {
    eval { delete_test_user($uid) };
  }
  for my $sid (@servers) {
    eval { delete_test_server($sid) };
  }
}

my $srv = create_test_server(name => "srv-server-${pid}", comment => 'Server CRUD test fixture');
push @servers, $srv;

my $super = create_test_user(username => "srvsuper_${pid}", email => "srvsuper_${pid}\@example.com", superuser => 1);
my $ruser  = create_test_user(username => "svcr_${pid}",  email => "svcr_${pid}\@example.com");
my $rwuser = create_test_user(username => "svcrw_${pid}", email => "svcrw_${pid}\@example.com");
my $nouser = create_test_user(username => "svcno_${pid}",  email => "svcno_${pid}\@example.com");
push @users, $super, $ruser, $rwuser, $nouser;
grant_server_access($ruser,  $srv, 'R');
grant_server_access($rwuser, $srv, 'RW');

sub _as {
  my ($u) = @_;
  $t->reset_session;
  return { 'X-Remote-User' => "${u}_${pid}\@example.com" };
}
my $SUPER = _as('srvsuper');
my $SVR_R  = _as('svcr');
my $SVR_RW = _as('svcrw');
my $NOACC  = _as('svcno');

my $URL = "/api/v1/servers";

# ========================================================================
# Read paths
# ========================================================================

subtest 'GET /servers - superuser sees fixture server' => sub {
  $t->get_ok($URL => $SUPER)
    ->status_is(200);
  my $body = $t->tx->res->json;
  ok(ref $body eq 'ARRAY', 'response is a bare array (no envelope)');
  my ($hit) = grep { $_->{name} eq "srv-server-${pid}" } @$body;
  ok($hit, 'fixture server present');
  is($hit->{id}, $srv, 'id matches');
  is($hit->{comment}, 'Server CRUD test fixture', 'comment matches');
};

subtest 'GET /servers - fixture filtered out without server permission' => sub {
  $t->get_ok($URL => $NOACC)
    ->status_is(200);
  my $body = $t->tx->res->json;
  my ($hit) = grep { $_->{name} eq "srv-server-${pid}" } @$body;
  ok(!$hit, 'fixture server not visible to unauthorized user');
};

subtest 'GET /servers/{server} - superuser' => sub {
  $t->get_ok("$URL/srv-server-${pid}" => $SUPER)
    ->status_is(200)
    ->json_is('/id'   => $srv)
    ->json_is('/name' => "srv-server-${pid}")
    ->json_is('/comment' => 'Server CRUD test fixture')
    ->json_is('/zones_only' => JSON::PP::false)
    ->json_is('/no_roots'   => JSON::PP::false);
};

subtest 'GET /servers/{server} - server R user can read' => sub {
  $t->get_ok("$URL/srv-server-${pid}" => $SVR_R)
    ->status_is(200)
    ->json_is('/name' => "srv-server-${pid}");
};

subtest 'GET /servers/{server} - no access denied' => sub {
  $t->get_ok("$URL/srv-server-${pid}" => $NOACC)
    ->status_is(403)
    ->json_is('/error' => 'Forbidden');
};

subtest 'GET /servers/{server} - non-existent returns 404' => sub {
  $t->get_ok("$URL/nosuchserver-${pid}" => $SUPER)
    ->status_is(404)
    ->json_is('/error' => 'Not Found');
};

# ========================================================================
# Write paths
# ========================================================================

# NewServer schema requires these alongside name (OpenAPI-validated).
sub _new_server {
  my (%extra) = @_;
  return {
    hostname   => "ns1.created-${pid}.example.com",
    hostaddr   => '10.55.0.1',
    hostmaster => "hostmaster.created-${pid}.example.com.",
    directory  => '/srv/named',
    %extra,
  };
}

subtest 'POST /servers - create' => sub {
  $t->post_ok($URL => $SUPER => json => _new_server(
    name       => "srv-created-${pid}",
    comment    => 'created via API',
    ttl        => 3600,
    zones_only => JSON::PP::true,
  ))
    ->status_is(201)
    ->json_is('/name'    => "srv-created-${pid}")
    ->json_is('/comment' => 'created via API')
    ->json_is('/ttl'     => 3600)
    ->json_is('/zones_only' => JSON::PP::true);

  my $id = $t->tx->res->json->{id};
  push @servers, $id;
};

subtest 'POST /servers - duplicate returns 409' => sub {
  $t->post_ok($URL => $SUPER => json => _new_server(name => "srv-created-${pid}"))
    ->status_is(409)
    ->json_is('/error' => 'Conflict');
};

subtest 'POST /servers - missing name returns 400' => sub {
  $t->post_ok($URL => $SUPER => json => { comment => 'no name' })
    ->status_is(400);
};

subtest 'POST /servers - non-superuser denied' => sub {
  $t->post_ok($URL => $SVR_RW => json => _new_server(name => "srv-denied-${pid}"))
    ->status_is(403)
    ->json_is('/error' => 'Forbidden');
};

subtest 'PUT /servers/{server} - scalar and boolean round-trip' => sub {
  $t->put_ok("$URL/srv-server-${pid}" => $SUPER => json => {
    comment    => 'updated comment',
    ttl        => 7200,
    hostmaster => 'hostmaster.example.com.',
    no_roots   => JSON::PP::true,
  })
    ->status_is(200)
    ->json_is('/comment'    => 'updated comment')
    ->json_is('/ttl'        => 7200)
    ->json_is('/hostmaster' => 'hostmaster.example.com.')
    ->json_is('/no_roots'   => JSON::PP::true)
    ->json_is('/zones_only' => JSON::PP::false);

  # Persisted
  $t->get_ok("$URL/srv-server-${pid}" => $SUPER)
    ->status_is(200)
    ->json_is('/comment' => 'updated comment')
    ->json_is('/no_roots' => JSON::PP::true);
};

subtest 'PUT /servers/{server} - array field round-trip (dhcp_l replace-all)' => sub {
  $t->put_ok("$URL/srv-server-${pid}" => $SUPER => json => {
    dhcp_l => [{ dhcp => '10.1.2.3', comment => 'first dhcp' }],
  })
    ->status_is(200)
    ->json_is('/dhcp_l/0/dhcp'    => '10.1.2.3')
    ->json_is('/dhcp_l/0/comment' => 'first dhcp');

  # Replace-all: new array replaces previous rows
  $t->put_ok("$URL/srv-server-${pid}" => $SUPER => json => {
    dhcp_l => [{ dhcp => '10.4.5.6' }],
  })
    ->status_is(200)
    ->json_is('/dhcp_l/0/dhcp' => '10.4.5.6')
    ->json_is('/dhcp_l/1' => undef);
};

subtest 'PUT /servers/{server} - server RW user can update' => sub {
  $t->put_ok("$URL/srv-server-${pid}" => $SVR_RW => json => { comment => 'rw edit' })
    ->status_is(200)
    ->json_is('/comment' => 'rw edit');
};

subtest 'PUT /servers/{server} - server R user denied' => sub {
  $t->put_ok("$URL/srv-server-${pid}" => $SVR_R => json => { comment => 'r edit' })
    ->status_is(403)
    ->json_is('/error' => 'Forbidden');
};

subtest 'PUT /servers/{server} - non-existent returns 404' => sub {
  $t->put_ok("$URL/nosuchserver-${pid}" => $SUPER => json => { comment => 'x' })
    ->status_is(404)
    ->json_is('/error' => 'Not Found');
};

subtest 'DELETE /servers/{server} - non-superuser denied' => sub {
  $t->delete_ok("$URL/srv-created-${pid}" => $SVR_RW)
    ->status_is(403)
    ->json_is('/error' => 'Forbidden');
};

subtest 'DELETE /servers/{server} - delete then 404' => sub {
  $t->delete_ok("$URL/srv-created-${pid}" => $SUPER)
    ->status_is(204);

  $t->get_ok("$URL/srv-created-${pid}" => $SUPER)
    ->status_is(404);

  pop @servers;  # already deleted
};

done_testing();
