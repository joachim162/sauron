use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/lib";

use SauronAPITest qw(
  setup_test_app
  create_test_user delete_test_user
  make_pat
);

my $t = setup_test_app();

# ========================================================================
# Auth error paths (no DB fixtures needed)
# ========================================================================

subtest 'GET /auth/me without authentication' => sub {
  $t->get_ok('/api/v1/auth/me')
    ->status_is(401)
    ->json_is('/error'   => 'Unauthorized')
    ->json_has('/message');
};

subtest 'POST /auth/login with missing body' => sub {
  $t->post_ok('/api/v1/auth/login')
    ->status_is(400)
    ->json_is('/error'   => 'Bad Request')
    ->json_is('/message' => 'email and password are required');
};

subtest 'POST /auth/login with missing password' => sub {
  $t->post_ok('/api/v1/auth/login' => json => { email => 'test@example.com' })
    ->status_is(400)
    ->json_is('/error'   => 'Bad Request')
    ->json_is('/message' => 'email and password are required');
};

subtest 'POST /auth/login with invalid email format' => sub {
  $t->post_ok('/api/v1/auth/login' => json => { email => 'not-an-email', password => 'secret' })
    ->status_is(400)
    ->json_is('/error'   => 'Bad Request')
    ->json_is('/message' => 'Invalid email format');
};

subtest 'POST /auth/login with non-existent user' => sub {
  $t->post_ok('/api/v1/auth/login' => json => { email => 'nobody@example.com', password => 'secret' })
    ->status_is(401)
    ->json_is('/error'   => 'Unauthorized')
    ->json_is('/message' => 'Invalid email or password');
};

subtest 'POST /auth/logout without session' => sub {
  $t->post_ok('/api/v1/auth/logout')
    ->status_is(200)
    ->json_is('/message' => 'Logged out');
};

subtest 'GET /auth/me with proxy auth for non-existent user' => sub {
  $t->get_ok('/api/v1/auth/me' => { 'X-Remote-User' => 'nobody@example.com' })
    ->status_is(401)
    ->json_is('/error'   => 'Unauthorized')
    ->json_like('/message' => qr/nobody\@example\.com/);
};

# ========================================================================
# Auth success paths (require DB fixtures)
# ========================================================================

my ($user_id, $pat_token);
my $test_username = 'apptest_' . $$;
my $test_email    = 'apptest_' . $$ . '@example.com';

# Ensure cleanup even if tests die
END {
  if ($user_id) {
    eval { delete_test_user($user_id); };
  }
}

subtest 'Setup test user and PAT' => sub {
  $user_id = create_test_user(
    username => $test_username,
    email    => $test_email,
    password => 'testpass123',
  );
  ok($user_id > 0, "Created test user id=$user_id");

  $pat_token = make_pat($user_id, 'test-token');
  ok(defined $pat_token, 'Created PAT');
  like($pat_token, qr/^sauron_sk_[0-9a-f]{64}$/, 'PAT has correct format');
};

subtest 'POST /auth/login with valid credentials' => sub {
  $t->post_ok('/api/v1/auth/login' => json => {
    email    => $test_email,
    password => 'testpass123',
  })
    ->status_is(200)
    ->json_has('/user')
    ->json_is('/user/username'    => $test_username)
    ->json_is('/user/email'       => $test_email)
    ->json_is('/user/auth_method' => 'password')
    ->json_is('/user/superuser'   => JSON::PP::false);

  # Verify session cookie was set
  my $cookie = $t->tx->res->cookie('bff_session');
  ok(defined $cookie, 'Session cookie set');
  ok(length($cookie->value) > 0, 'Session cookie has value');
};

subtest 'GET /auth/me with session cookie' => sub {
  $t->get_ok('/api/v1/auth/me')
    ->status_is(200)
    ->json_is('/user/username'    => $test_username)
    ->json_is('/user/auth_method' => 'password');
};

subtest 'GET /auth/me with proxy auth' => sub {
  # Reset session so we test proxy auth in isolation
  $t->reset_session;

  $t->get_ok('/api/v1/auth/me' => { 'X-Remote-User' => $test_email })
    ->status_is(200)
    ->json_is('/user/username'    => $test_username)
    ->json_is('/user/email'       => $test_email)
    ->json_is('/user/auth_method' => 'proxy');
};

subtest 'GET /api/v1/servers with Bearer auth (PAT)' => sub {
  $t->reset_session;

  $t->get_ok('/api/v1/servers' => { Authorization => "Bearer $pat_token" })
    ->status_is(200)
    ->json_is('' => []);
};

subtest 'POST /auth/logout destroys session' => sub {
  # Re-establish session first
  $t->post_ok('/api/v1/auth/login' => json => {
    email    => $test_email,
    password => 'testpass123',
  })->status_is(200);

  $t->post_ok('/api/v1/auth/logout')
    ->status_is(200)
    ->json_is('/message' => 'Logged out');

  # Session should now be invalid
  $t->get_ok('/api/v1/auth/me')
    ->status_is(401);
};

done_testing();
