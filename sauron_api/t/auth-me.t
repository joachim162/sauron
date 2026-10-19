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
  make_pat
);

my $t = setup_test_app();

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

my $srv  = create_test_server(name => "me-srv-${pid}",  comment => 'self defaults test');
my $srv2 = create_test_server(name => "me-srv2-${pid}", comment => 'self defaults test 2');
my $zone = create_test_zone(server_id => $srv,  name => "me-zone-${pid}.example.com");
my $zone2 = create_test_zone(server_id => $srv2, name => "me-zone2-${pid}.example.com");
push @servers, $srv, $srv2;
push @zones, $zone, $zone2;

my $me = create_test_user(
  username => "me_${pid}", email => "me_${pid}\@example.com", password => 'oldpass123');
my $other = create_test_user(
  username => "meother_${pid}", email => "meother_${pid}\@example.com");
my $pat_user = create_test_user(
  username => "mepat_${pid}", email => "mepat_${pid}\@example.com", password => 'patpass1');
my $pwdless;
{
  Sauron::BackEnd::set_muser('test');
  $pwdless = Sauron::BackEnd::add_record('users', {
    username  => "mepwl_${pid}",
    name      => 'Passwordless',
    email     => "mepwl_${pid}\@example.com",
    superuser => 'f',
    flags     => 0,
  });
  die "Failed to create passwordless fixture: $pwdless" unless $pwdless > 0;
}
push @users, $me, $other, $pat_user, $pwdless;

sub _proxy {
  my ($email) = @_;
  $t->reset_session;
  return { 'X-Remote-User' => $email };
}

my $ME = _proxy("me_${pid}\@example.com");

sub _login_me {
  $t->reset_session;
  $t->post_ok('/api/v1/auth/login' => json => {
    email => "me_${pid}\@example.com", password => 'oldpass123',
  })->status_is(200);
}

# ========================================================================
# GET /auth/me exposes email_notify
# ========================================================================

subtest 'GET /auth/me exposes email_notify' => sub {
  $t->get_ok('/api/v1/auth/me' => $ME)->status_is(200)
    ->json_is('/user/email' => "me_${pid}\@example.com")
    ->json_is('/user/email_notify' => JSON::PP::false);
};

# ========================================================================
# PUT /auth/me — email preferences
# ========================================================================

subtest 'PUT /auth/me updates email_notify and persists' => sub {
  $t->put_ok('/api/v1/auth/me' => $ME => json => { email_notify => JSON::PP::true })
    ->status_is(200)->json_is('/user/email_notify' => JSON::PP::true);
  $t->get_ok('/api/v1/auth/me' => $ME)->status_is(200)
    ->json_is('/user/email_notify' => JSON::PP::true);
  my @q;
  Sauron::DB::db_query('SELECT flags FROM users WHERE id=?', \@q, $me);
  is($q[0][0], 1, 'flags bit persisted');

  $t->put_ok('/api/v1/auth/me' => $ME => json => { email_notify => JSON::PP::false })
    ->status_is(200)->json_is('/user/email_notify' => JSON::PP::false);
};

subtest 'PUT /auth/me with no updatable fields is a no-op' => sub {
  _login_me();
  my @q;
  Sauron::DB::db_query('SELECT mdate, muser FROM users WHERE id=?', \@q, $me);
  my ($mdate0, $muser0) = @{$q[0]};
  sleep 1;

  $t->put_ok('/api/v1/auth/me' => json => {})->status_is(200)
    ->json_is('/user/email' => "me_${pid}\@example.com");

  Sauron::DB::db_query('SELECT mdate, muser FROM users WHERE id=?', \@q, $me);
  my ($mdate1, $muser1) = @{$q[0]};
  is($mdate1, $mdate0, 'mdate not bumped');
  is($muser1, $muser0, 'muser not bumped');
};

subtest 'PUT /auth/me manages default server/zone' => sub {
  _login_me();

  $t->put_ok('/api/v1/auth/me' => json => {
    default_server_id => $srv, default_zone_id => $zone,
  })->status_is(200)
    ->json_is('/user/default_server_id' => $srv)
    ->json_is('/user/default_zone_id'   => $zone);

  $t->put_ok('/api/v1/auth/me' => json => {
    default_server_id => undef, default_zone_id => undef,
  })->status_is(200)
    ->json_is('/user/default_server_id' => undef)
    ->json_is('/user/default_zone_id'   => undef);

  $t->put_ok('/api/v1/auth/me' => json => { default_server_id => $srv })
    ->status_is(200)
    ->json_is('/user/default_server_id' => $srv)
    ->json_is('/user/default_zone_id'   => undef);

  $t->put_ok('/api/v1/auth/me' => json => {
    default_server_id => $srv2, default_zone_id => $zone2,
  })->status_is(200);

  # same server: existing zone is preserved
  $t->put_ok('/api/v1/auth/me' => json => { default_server_id => $srv2 })
    ->status_is(200)
    ->json_is('/user/default_zone_id' => $zone2);

  # switching the server with a stale zone is rejected
  $t->put_ok('/api/v1/auth/me' => json => { default_server_id => $srv })
    ->status_is(400)->json_is('/error' => 'Bad Request');

  # a zone requires a server
  $t->put_ok('/api/v1/auth/me' => json => {
    default_server_id => undef, default_zone_id => undef,
  })->status_is(200);
  $t->put_ok('/api/v1/auth/me' => json => { default_zone_id => $zone })
    ->status_is(400)->json_is('/error' => 'Bad Request');

  $t->put_ok('/api/v1/auth/me' => json => { default_server_id => 999999999 })
    ->status_is(400)->json_is('/error' => 'Bad Request', 'unknown server');
};

subtest 'PUT /auth/me requires authentication' => sub {
  $t->reset_session;
  $t->put_ok('/api/v1/auth/me' => json => { email_notify => JSON::PP::true })
    ->status_is(401);
};

# ========================================================================
# PUT /auth/me — email
# ========================================================================

subtest 'PUT /auth/me validation' => sub {
  $t->put_ok('/api/v1/auth/me' => $ME => json => { email => 'not-an-email' })
    ->status_is(400);
  $t->put_ok('/api/v1/auth/me' => $ME => json => { email => "meother_${pid}\@example.com" })
    ->status_is(409)->json_is('/error' => 'Conflict');
  $t->put_ok('/api/v1/auth/me' => $ME => json => { name => 'New Name' })
    ->status_is(400);
  $t->put_ok('/api/v1/auth/me' => $ME => json => { username => 'renamed' })
    ->status_is(400);
};

subtest 'PUT /auth/me changes and clears email (session auth survives)' => sub {
  _login_me();
  $t->put_ok('/api/v1/auth/me' => json => { email => "me-new_${pid}\@example.com" })
    ->status_is(200)->json_is('/user/email' => "me-new_${pid}\@example.com");
  $t->get_ok('/api/v1/auth/me')->status_is(200)
    ->json_is('/user/email' => "me-new_${pid}\@example.com");

  $t->put_ok('/api/v1/auth/me' => json => { email => undef })->status_is(200)
    ->json_is('/user/email' => undef);
  $t->get_ok('/api/v1/auth/me')->status_is(200)->json_is('/user/email' => undef);

  $t->put_ok('/api/v1/auth/me' => json => { email => "me_${pid}\@example.com" })->status_is(200);
};

# ========================================================================
# POST /auth/me/password
# ========================================================================

subtest 'password change requires fields and valid current password' => sub {
  _login_me();
  $t->post_ok('/api/v1/auth/me/password')->status_is(400);
  $t->post_ok('/api/v1/auth/me/password' => json => { current_password => 'oldpass123' })
    ->status_is(400);
  $t->post_ok('/api/v1/auth/me/password' => json => {
    current_password => 'wrongpass', new_password => 'newpass2',
  })->status_is(403)->json_is('/error' => 'Forbidden');

  # Unix crypt mode truncates at 8 bytes; reject instead of storing silently
  $t->post_ok('/api/v1/auth/me/password' => json => {
    current_password => 'oldpass123', new_password => 'toolongpass9',
  })->status_is(400)->json_like('/message' => qr/8 bytes/);
};

subtest 'password change succeeds, session survives, old password dies' => sub {
  $t->post_ok('/api/v1/auth/me/password' => json => {
    current_password => 'oldpass123', new_password => 'newpass2',
  })->status_is(200)->json_is('/message' => 'Password changed');

  $t->get_ok('/api/v1/auth/me')->status_is(200, 'session still valid');

  $t->reset_session;
  $t->post_ok('/api/v1/auth/login' => json => {
    email => "me_${pid}\@example.com", password => 'oldpass123',
  })->status_is(401, 'old password rejected');
  $t->post_ok('/api/v1/auth/login' => json => {
    email => "me_${pid}\@example.com", password => 'newpass2',
  })->status_is(200, 'new password accepted');

  my @q;
  Sauron::DB::db_query('SELECT last_pwd, password FROM users WHERE id=?', \@q, $me);
  ok($q[0][0] > 0, 'last_pwd updated');
  isnt($q[0][1], '', 'password stored');
};

subtest 'password change requires email login mode with password support' => sub {
  $t->app->config->{auth}{mode} = 'oidc';
  $t->post_ok('/api/v1/auth/me/password' => _proxy("me_${pid}\@example.com") => json => {
    current_password => 'newpass2', new_password => 'thirdpa3',
  })->status_is(403)->json_is('/error' => 'Forbidden');
  $t->app->config->{auth}{mode} = 'password';

  $t->post_ok('/api/v1/auth/me/password' => $ME => json => {
    current_password => 'newpass2', new_password => 'thirdpa3',
  })->status_is(200);
};

subtest 'PAT authentication reaches self-service endpoints' => sub {
  my $pat = make_pat($pat_user, 'me-test');
  $t->reset_session;
  my $bearer = { Authorization => "Bearer $pat" };

  $t->get_ok('/api/v1/auth/me' => $bearer)->status_is(200)
    ->json_is('/user/username'    => "mepat_${pid}")
    ->json_is('/user/auth_method' => 'pat');

  $t->put_ok('/api/v1/auth/me' => $bearer => json => {
    email_notify => JSON::PP::true,
  })->status_is(200)->json_is('/user/email_notify' => JSON::PP::true);

  $t->post_ok('/api/v1/auth/me/password' => $bearer => json => {
    current_password => 'patpass1', new_password => 'patpass2',
  })->status_is(200)->json_is('/message' => 'Password changed');

  $t->get_ok("/api/v1/users/$pat_user" => $bearer)->status_is(200);

  $t->get_ok('/api/v1/auth/me' => { Authorization => 'Bearer invalid-token' })
    ->status_is(401)->json_is('/error' => 'Unauthorized');
};

subtest 'PAT is rejected for locked and expired accounts' => sub {
  my $pat = make_pat($pat_user, 'lock-test');
  my $bearer = { Authorization => "Bearer $pat" };

  Sauron::DB::db_exec(
    "UPDATE users SET password='LOCKED:' || password WHERE id=$pat_user");
  $t->get_ok('/api/v1/auth/me' => $bearer)->status_is(401);
  $t->get_ok("/api/v1/users/$pat_user" => $bearer)->status_is(401);

  Sauron::DB::db_exec(
    "UPDATE users SET password=substr(password, 8), expiration=1 WHERE id=$pat_user");
  $t->get_ok('/api/v1/auth/me' => $bearer)->status_is(401);
  $t->get_ok("/api/v1/users/$pat_user" => $bearer)->status_is(401);
};

subtest 'passwordless (proxy/SSO) account cannot set a password' => sub {
  $t->post_ok('/api/v1/auth/me/password' => _proxy("mepwl_${pid}\@example.com") => json => {
    current_password => 'anything123', new_password => 'whatever123',
  })->status_is(409)->json_is('/error' => 'Conflict');
};

done_testing();
