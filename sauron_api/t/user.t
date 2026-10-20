use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/lib";

use SauronAPITest qw(
  setup_test_app
  create_test_user delete_test_user
);

my $t = setup_test_app();

my $pid = $$;
sub _uname { my ($suffix) = @_; return "u-${suffix}-${pid}"; }
sub _uemail { my ($suffix) = @_; return "u-${suffix}-${pid}\@example.com"; }

my @users;

END {
  for my $uid (@users) {
    eval { delete_test_user($uid); };
  }
}

my $super    = create_test_user(username => _uname('super'),  email => _uemail('super'),  superuser => 1);
my $ordinary = create_test_user(username => _uname('ord'),    email => _uemail('ord'));
my $other    = create_test_user(username => _uname('other'),  email => _uemail('other'));
my $locked   = create_test_user(username => _uname('locked'), email => _uemail('locked'));
my $closed   = create_test_user(username => _uname('closed'), email => _uemail('closed'));
push @users, $super, $ordinary, $other, $locked, $closed;

Sauron::DB::db_exec("UPDATE users SET password='LOCKED:P' WHERE id=$locked");
Sauron::DB::db_exec("UPDATE users SET password='LOCKED:REMOVED', name='Removed User', email=NULL WHERE id=$closed");

sub _hdr {
  my ($email) = @_;
  $t->reset_session;
  return { 'X-Remote-User' => $email };
}

my $SUPER = _hdr(_uemail('super'));
my $ORD   = _hdr(_uemail('ord'));
my $BASE  = '/api/v1/users';

# ========================================================================
# AUTHORIZATION
# ========================================================================

subtest 'list requires authentication and superuser' => sub {
  $t->reset_session;
  $t->get_ok($BASE)->status_is(401);

  $t->get_ok($BASE => $ORD)->status_is(403)->json_is('/error' => 'Forbidden');
  $t->get_ok($BASE => $SUPER)->status_is(200);
};

subtest 'detail: self or superuser only' => sub {
  $t->reset_session;
  $t->get_ok("$BASE/$ordinary")->status_is(401);

  $t->get_ok("$BASE/$ordinary" => $ORD)->status_is(200)
    ->json_is('/username' => _uname('ord'));
  $t->get_ok("$BASE/$other" => $ORD)->status_is(403)->json_is('/error' => 'Forbidden');
  $t->get_ok("$BASE/$other" => $SUPER)->status_is(200)
    ->json_is('/username' => _uname('other'));

  $t->get_ok("$BASE/999999999" => $SUPER)->status_is(404)->json_is('/error' => 'Not Found');
  $t->get_ok("$BASE/999999999" => $ORD)->status_is(403);
};

subtest 'administrative writes require superuser' => sub {
  $t->post_ok($BASE => $ORD => json => { username => _uname('new') })->status_is(403);
  $t->put_ok("$BASE/$ordinary" => $ORD => json => { comment => 'x' })->status_is(403);
  $t->delete_ok("$BASE/$other" => $ORD)->status_is(403);
};

# ========================================================================
# LIST
# ========================================================================

subtest 'list returns paginated user model' => sub {
  $t->get_ok($BASE => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  ok(ref $j->{data} eq 'ARRAY' && exists $j->{metadata}, 'envelope');
  my ($found) = grep { $_->{username} eq _uname('ord') } @{$j->{data}};
  ok($found, 'fixture listed');
  ok(!exists $found->{password}, 'password not exposed');

  $t->get_ok("$BASE?username=" . _uname('locked') => $SUPER)->status_is(200);
  my ($f) = grep { $_->{username} eq _uname('locked') } @{$t->tx->res->json->{data}};
  ok($f, 'username filter');
  is($t->tx->res->json->{metadata}{filters}[0]{value}, _uname('locked'), 'filter echo');

  $t->get_ok("$BASE?locked=true" => $SUPER)->status_is(200);
  ok((grep { $_->{id} == $locked } @{$t->tx->res->json->{data}}), 'locked filter');
  $t->get_ok("$BASE?closed=true" => $SUPER)->status_is(200);
  ok((grep { $_->{id} == $closed } @{$t->tx->res->json->{data}}), 'closed filter includes closed accounts');

  $t->get_ok("$BASE?username=" . '^(u-ord|u-super)' . "&sort=username:desc" => $SUPER)->status_is(200);
  my @names = map { $_->{username} } @{$t->tx->res->json->{data}};
  is_deeply(\@names, [ reverse sort @names ], 'username sort desc');

  $t->get_ok("$BASE?bogus=1" => $SUPER)->status_is(400);
  $t->get_ok("$BASE?sort=nope" => $SUPER)->status_is(400);
  $t->get_ok("$BASE?per_page=101" => $SUPER)->status_is(400);
};

# ========================================================================
# DETAIL MODEL
# ========================================================================

subtest 'detail exposes account fields, no credentials' => sub {
  $t->get_ok("$BASE/$locked" => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  is($j->{username}, _uname('locked'), 'username');
  is($j->{locked}, JSON::PP::true, 'locked marker');
  is($j->{closed}, JSON::PP::false, 'not closed');
  is($j->{superuser}, JSON::PP::false, 'not superuser');
  is($j->{email_notify}, JSON::PP::false, 'email_notify off');
  is($j->{expiration}, 0, 'expiration default');
  is($j->{default_server_id}, undef, 'no default server');
  is($j->{last_login_at}, undef, 'never logged in');
  ok(!exists $j->{password}, 'password not exposed');
  ok(exists $j->{cdate} && exists $j->{cuser} && exists $j->{mdate} && exists $j->{muser}, 'audit fields');

  $t->get_ok("$BASE/$closed" => $SUPER)->status_is(200);
  $j = $t->tx->res->json;
  is($j->{locked}, JSON::PP::true, 'closed implies locked');
  is($j->{closed}, JSON::PP::true, 'closed marker');
  is($j->{name}, 'Removed User', 'legacy closed display name');
  is($j->{email}, undef, 'email cleared on close');
};

done_testing();
