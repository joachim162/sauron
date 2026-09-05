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
  ok(ref $body eq 'HASH' && ref $body->{data} eq 'ARRAY', 'response is the paginated envelope');
  is($body->{metadata}{pagination}{page}, 1, 'default page 1');
  is($body->{metadata}{pagination}{per_page}, 50, 'default per_page 50');
  my ($hit) = grep { $_->{name} eq "srv-server-${pid}" } @{$body->{data}};
  ok($hit, 'fixture server present');
  is($hit->{id}, $srv, 'id matches');
  is($hit->{comment}, 'Server CRUD test fixture', 'comment matches');
};

subtest 'GET /servers - fixture filtered out without server permission' => sub {
  $t->get_ok($URL => $NOACC)
    ->status_is(200);
  my $body = $t->tx->res->json;
  my ($hit) = grep { $_->{name} eq "srv-server-${pid}" } @{$body->{data}};
  ok(!$hit, 'fixture server not visible to unauthorized user');
  is($body->{metadata}{pagination}{total}, 0, 'no-access user totals 0');
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

# NewServer schema requires name, hostaddr, directory (CGI parity);
# hostname and hostmaster are optional.
sub _new_server {
  my (%extra) = @_;
  return {
    hostaddr  => '10.55.0.1',
    directory => '/srv/named',
    %extra,
  };
}

subtest 'POST /servers - create (minimal, CGI parity)' => sub {
  # hostname and hostmaster omitted: optional per the legacy CGI form
  $t->post_ok($URL => $SUPER => json => _new_server(
    name       => "srv-created-${pid}",
    comment    => 'created via API',
    ttl        => 3600,
    zones_only => JSON::PP::true,
  ))
    ->status_is(201)
    ->header_like('Location' => qr{/api/v1/servers/srv-created-${pid}$})
    ->json_is('/name'    => "srv-created-${pid}")
    ->json_is('/comment' => 'created via API')
    ->json_is('/ttl'     => 3600)
    ->json_is('/hostname' => undef)
    ->json_is('/hostmaster' => undef)
    ->json_is('/zones_only' => JSON::PP::true);

  my $id = $t->tx->res->json->{id};
  push @servers, $id;
};

subtest 'POST /servers - hostname and hostmaster accepted when provided' => sub {
  $t->post_ok($URL => $SUPER => json => _new_server(
    name       => "srv-full-${pid}",
    hostname   => "ns1.full-${pid}.example.com",
    hostmaster => "hostmaster.full-${pid}.example.com.",
  ))
    ->status_is(201)
    ->json_is('/hostname'   => "ns1.full-${pid}.example.com")
    ->json_is('/hostmaster' => "hostmaster.full-${pid}.example.com.");

  my $id = $t->tx->res->json->{id};
  push @servers, $id;
};

subtest 'POST /servers - hostaddr and directory stay required (CGI parity)' => sub {
  $t->post_ok($URL => $SUPER => json => { name => "srv-nohostaddr-${pid}", directory => '/srv/named' })
    ->status_is(400)
    ->json_has('/errors');

  $t->post_ok($URL => $SUPER => json => { name => "srv-nodir-${pid}", hostaddr => '10.55.0.2' })
    ->status_is(400)
    ->json_has('/errors');
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
  my $del_name = "srv-created-${pid}";
  my $del_id = Sauron::BackEnd::get_server_id($del_name);
  ok($del_id > 0, "resolved server to delete (id=$del_id)");

  $t->delete_ok("$URL/$del_name" => $SUPER)
    ->status_is(204);

  $t->get_ok("$URL/$del_name" => $SUPER)
    ->status_is(404);

  @servers = grep { $_ != $del_id } @servers;
};

# ========================================================================
# PAGINATION (always-on envelope) + AUTHZ ALLOWLIST TOTALS
# ========================================================================

subtest 'GET /servers - pagination envelope and page coverage' => sub {
  $t->get_ok($URL => $SUPER)->status_is(200);
  my $env = $t->tx->res->json;
  my $total = $env->{metadata}{pagination}{total};
  ok($total >= 1, "at least the fixture server is visible (total=$total)");
  is($env->{metadata}{pagination}{page}, 1, 'default page 1');
  is($env->{metadata}{pagination}{per_page}, 50, 'default per_page 50');

  # Pages cover the visible set exactly, without duplicates
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
  is(scalar(grep { $_ != 1 } values %seen), 0, 'no duplicate servers across pages');

  $t->get_ok("$URL?page=0&per_page=2" => $SUPER)->status_is(400);
  $t->get_ok("$URL?page=1&per_page=101" => $SUPER)->status_is(400);
};

subtest 'GET /servers - totals reflect the authz allowlist' => sub {
  # Server-R user: exactly their one grant is counted
  $t->get_ok($URL => $SVR_R)->status_is(200);
  my $env = $t->tx->res->json;
  is($env->{metadata}{pagination}{total}, 1, 'server-R user totals exactly their grant');
  is($env->{data}[0]{name}, "srv-server-${pid}", 'visible server is the fixture');

  # Server-RW user: rule contains R, same single grant
  $t->get_ok($URL => $SVR_RW)->status_is(200);
  is($t->tx->res->json->{metadata}{pagination}{total}, 1,
     'server-RW user totals exactly their grant');

  # No-access user: empty allowlist short-circuits to an empty page
  $t->get_ok($URL => $NOACC)->status_is(200);
  my $none = $t->tx->res->json;
  is($none->{metadata}{pagination}{total}, 0, 'no-access user totals 0');
  is_deeply($none->{data}, [], 'no-access user data empty');
  is($none->{metadata}{pagination}{total_pages}, 0, 'no-access total_pages 0');
};

done_testing();
