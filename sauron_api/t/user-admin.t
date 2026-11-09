use Mojo::Base -strict;

use Test::More;
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/lib";
use SauronAPITest qw(setup_test_app create_test_user delete_test_user
  create_test_server delete_test_server create_test_zone make_pat);

my $t = setup_test_app();
my $pid = $$;
my (@users, $server, $group, $net);
my $trigger = "reject_user_audit_$pid";
my $seq = 0;
my $BASE = '/api/v1/users';

sub _query {
  my ($sql, @bind) = @_;
  my @rows;
  die Sauron::DB::db_errormsg() if Sauron::DB::db_query($sql, \@rows, @bind) < 0;
  return \@rows;
}

END {
  eval { Sauron::DB::db_exec("DROP TRIGGER IF EXISTS $trigger ON history"); };
  for my $table (qw(user_rights history)) {
    eval { Sauron::DB::db_exec("DROP TRIGGER IF EXISTS reject_initial_${table}_$pid ON $table"); };
  }
  if ($group) {
    eval { _query('DELETE FROM user_rights WHERE type=1 AND ref=? RETURNING id', $group); };
    eval { _query('DELETE FROM user_groups WHERE id=? RETURNING id', $group); };
  }
  eval { Sauron::BackEnd::delete_net($net); } if $net;
  eval { delete_test_server($server); } if $server;
  for my $id (@users) {
    eval { _query('DELETE FROM history WHERE type=5 AND ref=? RETURNING id', $id); };
    eval { delete_test_user($id); };
  }
}

my $super = create_test_user(username => "ua-admin-$pid", email => "ua-admin-$pid\@example.com", superuser => 1);
my $ordinary = create_test_user(username => "ua-user-$pid", email => "ua-user-$pid\@example.com");
push @users, $super, $ordinary;
my $SUPER = {'X-Remote-User' => "ua-admin-$pid\@example.com"};
my $ORD = {'X-Remote-User' => "ua-user-$pid\@example.com"};
$server = create_test_server(name => "ua-server-$pid");
my $zone = create_test_zone(server_id => $server, name => "ua-$pid.example.com");
$group = Sauron::BackEnd::add_record('user_groups', {name => "ua-group-$pid", comment => 'Membership reference'});
die 'Group fixture failed' unless $group > 0;
$net = Sauron::BackEnd::add_record('nets', {server => $server, net => '192.0.2.0/24', netname => "ua-$pid"});
die 'Net fixture failed' unless $net > 0;

sub _new {
  my (%fields) = @_;
  my $name = 'ua-new-' . $pid . '-' . ++$seq;
  $t->reset_session;
  $t->post_ok($BASE => $SUPER => json => {username => $name, password => 'testpass', %fields})->status_is(201);
  my $rows = _query('SELECT id FROM users WHERE username=?', $fields{username} // $name);
  push @users, $rows->[0][0] if @$rows;
  die $t->tx->res->body unless $t->tx->res->code == 201;
  return $t->tx->res->json;
}

sub _legacy_passwordless {
  my (%fields) = @_;
  my $name = 'ua-legacy-' . $pid . '-' . ++$seq;
  my $id = Sauron::BackEnd::add_record('users', {
    username => $name, password => undef, email => $fields{email}, flags => 0,
    superuser => $fields{superuser} ? 't' : 'f',
  });
  die 'Legacy passwordless fixture failed' unless $id > 0;
  push @users, $id;
  return {id => $id, username => $name};
}

sub _history_count {
  my ($id) = @_;
  return _query('SELECT COUNT(*) FROM history WHERE type=5 AND ref=?', $id)->[0][0];
}

sub _credentials {
  my ($id) = @_;
  my $pat = make_pat($id, "ua-$pid");
  my $session = Sauron::BackEnd::create_session($id, 'oidc', '127.0.0.1', 3600);
  return ($pat, $session);
}

sub _no_credentials {
  my ($id) = @_;
  is(_query('SELECT COUNT(*) FROM personal_access_tokens WHERE user_id=?', $id)->[0][0], 0, 'PATs revoked');
  is(_query('SELECT COUNT(*) FROM bff_sessions WHERE user_id=?', $id)->[0][0], 0, 'sessions revoked');
}

subtest 'all administrative routes enforce authentication and superuser' => sub {
  my @requests = (
    [post => $BASE, {username => "ua-denied-$pid", password => 'testpass'}],
    [put => "$BASE/$ordinary", {superuser => JSON::PP::true}],
    [delete => "$BASE/$ordinary"],
    (map { [post => "$BASE/$ordinary/$_"] } qw(lock unlock close)),
    [post => "$BASE/$ordinary/password", {password => 'newpass1'}],
    [get => "$BASE/$ordinary/rights"],
    [post => "$BASE/$ordinary/rights", {kind => 'level', value => 1}],
    [delete => "$BASE/$ordinary/rights"],
    [delete => "$BASE/$ordinary/rights/1"],
    [get => '/api/v1/user-groups'],
  );
  for my $request (@requests) {
    my ($verb, $path, $body) = @$request;
    my $method = "${verb}_ok";
    $t->reset_session;
    $t->$method($path, defined $body ? (json => $body) : ())->status_is(401);
    $t->reset_session;
    $t->$method($path => $ORD, defined $body ? (json => $body) : ())->status_is(403);
  }
};

subtest 'create accounts, validate identity, and grant read access from paired defaults' => sub {
  my $user = _new(default_server_id => $server, default_zone_id => $zone, email_notify => JSON::PP::true);
  my $id = $user->{id};
  like($t->tx->res->headers->location // '', qr{/users/$id$}, 'Location identifies account');
  is($user->{default_server_id}, $server, 'default server');
  is($user->{default_zone_id}, $zone, 'default zone');
  is($user->{email_notify}, JSON::PP::true, 'notification preference');
  is($user->{superuser}, JSON::PP::false, 'not superuser by default');
  ok(!exists $user->{password}, 'no password returned');
  is(Sauron::Util::pwd_check('testpass', _query('SELECT password FROM users WHERE id=?', $id)->[0][0]),
    0, 'required password stored as a usable hash');
  is($user->{email}, undef, 'administrator may create an email-less account');
  $t->get_ok("$BASE/$id/rights" => $SUPER)->status_is(200)
    ->json_is('/metadata/pagination/total' => 2)
    ->json_is('/data/0/kind' => 'server')->json_is('/data/0/server_id' => $server)
    ->json_is('/data/0/mode' => 'R')->json_is('/data/0/source' => 'direct')
    ->json_is('/data/1/kind' => 'zone')->json_is('/data/1/zone_id' => $zone)
    ->json_is('/data/1/mode' => 'R')->json_is('/data/1/source' => 'direct');
  is(_history_count($id), 3, 'account and both initial grants audited');
  my $pat = make_pat($id, 'initial-access');
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {Authorization => "Bearer $pat"})->status_is(200)
    ->json_is("/permissions/server/$server" => 'R')
    ->json_is("/permissions/zone/$zone" => 'R')
    ->json_is('/permissions/alevel' => 0);
  my $password_user = _new(password => 'safe1234', email => "ua-login-$pid\@example.com");
  my $stored = _query('SELECT password,last_pwd FROM users WHERE id=?', $password_user->{id})->[0];
  isnt($stored->[0], 'safe1234', 'password hashed');
  is(Sauron::Util::pwd_check('safe1234', $stored->[0]), 0, 'hash verifies');
  ok($stored->[1] > 0, 'password timestamp');
  $t->post_ok($BASE => $SUPER => json => {username => $user->{username}, password => 'testpass'})->status_is(409);
  for my $input (
    {}, {username => 'Bad_User'}, {username => "ua-invalid-$pid", password => ''},
    {username => "ua-invalid-$pid", password => '123456789'},
    {username => "ua-invalid-$pid", email => 'invalid'},
    {username => "ua-invalid-$pid", default_zone_id => $zone},
    {username => "ua-invalid-$pid", default_server_id => 999999999},
    {username => "ua-invalid-$pid", expiration => -1},
    {username => "ua-invalid-$pid", rights => []}
  ) {
    $t->post_ok($BASE => $SUPER => json => {password => 'testpass', %$input})->status_is(400);
  }
  $t->post_ok($BASE => $SUPER => json => {
    username => "ua-invalid-$pid", password => 'testpass', email => "ua-login-$pid\@example.com",
  })->status_is(409);
};

subtest 'creation requires a non-empty password in password and both modes' => sub {
  for my $mode (qw(password both)) {
    local $t->app->config->{auth}{mode} = $mode;
    my $name = "ua-required-password-$mode-$pid";
    for my $fields ({}, {password => undef}, {password => ''}) {
      $t->post_ok($BASE => $SUPER => json => {username => $name, %$fields})->status_is(400);
      is(scalar @{_query('SELECT id FROM users WHERE username=?', $name)}, 0, 'no account created');
      is(_query('SELECT COUNT(*) FROM history WHERE uid=? AND type=5 AND info LIKE ?',
        $super, "%$name%")->[0][0], 0, 'no successful creation history');
    }
    my $user = _new(password => 'safe1234');
    ok($user->{last_password_change_at} > 0, 'initial password timestamp returned');
    ok(!exists $user->{password}, 'password not returned');
  }
};

subtest 'initial grants require paired defaults and a non-superuser' => sub {
  for my $fields ({}, {default_server_id => $server}, {
    default_server_id => $server, default_zone_id => $zone, superuser => JSON::PP::true,
  }) {
    my $user = _new(%$fields);
    $t->get_ok("$BASE/$user->{id}/rights" => $SUPER)->status_is(200)
      ->json_is('/data' => [])->json_is('/metadata/pagination/total' => 0);
    is(_history_count($user->{id}), 1, 'only account creation audited');
  }
};

subtest 'ordinary self-service requires email but administrators may maintain email-less accounts' => sub {
  my $user = _new;
  my $id = $user->{id};
  $t->put_ok("$BASE/$id" => $SUPER => json => {comment => 'Still email-less'})
    ->status_is(200)->json_is('/email' => undef);
  my $pat = make_pat($id, 'email-required');
  my $bearer = {Authorization => "Bearer $pat"};
  my $before = _query('SELECT mdate,muser,flags FROM users WHERE id=?', $id);
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => $bearer)->status_is(200)
    ->json_is('/user/email' => undef)->json_is('/rights' => []);
  for my $input ({}, {email_notify => JSON::PP::true}, {default_server_id => $server},
    {email => undef}, {email => ''}, {email => '   '}, {email => 'bad!@example.com'}) {
    $t->put_ok('/api/v1/auth/me' => $bearer => json => $input)->status_is(400);
  }
  is_deeply(_query('SELECT mdate,muser,flags FROM users WHERE id=?', $id), $before,
    'rejected personal settings do not change the record');
  $t->put_ok('/api/v1/auth/me' => $bearer => json => {
    email => "ua-self-$pid\@example.com", email_notify => JSON::PP::true,
  })->status_is(200)->json_is('/user/email' => "ua-self-$pid\@example.com");
  $t->put_ok('/api/v1/auth/me' => $bearer => json => {email_notify => JSON::PP::false})
    ->status_is(200)->json_is('/user/email' => "ua-self-$pid\@example.com");
  $t->put_ok("$BASE/$id" => $SUPER => json => {email => undef})->status_is(200)
    ->json_is('/email' => undef);
  $t->get_ok('/api/v1/auth/me' => $bearer)->status_is(200)->json_is('/user/email' => undef);
  $t->put_ok('/api/v1/auth/me' => $bearer => json => {})->status_is(400);

  my $admin = _new(superuser => JSON::PP::true);
  my $admin_pat = make_pat($admin->{id}, 'admin-email-optional');
  my $admin_bearer = {Authorization => "Bearer $admin_pat"};
  $t->put_ok('/api/v1/auth/me' => $admin_bearer => json => {email_notify => JSON::PP::true})
    ->status_is(200)->json_is('/user/email' => undef);
  $t->put_ok('/api/v1/auth/me' => $admin_bearer => json => {email => "ua-self-admin-$pid\@example.com"})
    ->status_is(200);
  $t->put_ok('/api/v1/auth/me' => $admin_bearer => json => {email => undef})
    ->status_is(200)->json_is('/user/email' => undef);
};

subtest 'administrative email validation follows the legacy CGI' => sub {
  my $email = "UA.Name_$pid+tag-test\@Example.com";
  my $user = _new(email => $email);
  my $id = $user->{id};
  is($user->{email}, $email, 'legacy local-part characters preserved');
  my $history = _history_count($id);
  for my $invalid ('bad!@example.com', 'bad@-example.com',
    'bad@example..com', 'bad@example-.com', 'bad@@example.com') {
    $t->post_ok($BASE => $SUPER => json => {
      username => "ua-email-invalid-$pid", password => 'testpass', email => $invalid,
    })->status_is(400);
    $t->put_ok("$BASE/$id" => $SUPER => json => {email => $invalid})->status_is(400);
  }
  $t->get_ok("$BASE/$id" => $SUPER)->status_is(200)->json_is('/email' => $email);
  is(_history_count($id), $history, 'rejected emails do not create history');
  is(scalar @{_query('SELECT id FROM users WHERE username=?', "ua-email-invalid-$pid")},
    0, 'rejected emails do not create accounts');
  $t->put_ok("$BASE/$id" => $SUPER => json => {email => "ua-$pid\@intranet"})
    ->status_is(200)->json_is('/email' => "ua-$pid\@intranet");
};

subtest 'partial updates, renames, clearing fields and stable IDs' => sub {
  my $user = _new(name => 'Original', email => "ua-edit-$pid\@example.com", email_notify => JSON::PP::true);
  my $id = $user->{id};
  $t->put_ok("$BASE/$id" => $SUPER => json => {
    username => "ua-renamed-$pid", name => 'Renamed', comment => "Admin's note", email => "ua-renamed-$pid\@example.com",
    default_server_id => $server, default_zone_id => $zone, expiration => time + 86400,
  })->status_is(200)->json_is('/id' => $id)->json_is('/username' => "ua-renamed-$pid")
    ->json_is('/email_notify' => JSON::PP::true)->json_is('/muser' => "ua-admin-$pid");
  $t->get_ok("$BASE/$id/rights" => $SUPER)->status_is(200)
    ->json_is('/metadata/pagination/total' => 0);
  $t->put_ok("$BASE/$id" => $SUPER => json => {email => undef, comment => undef, expiration => undef,
    default_server_id => undef, default_zone_id => undef})->status_is(200)
    ->json_is('/email' => undef)->json_is('/expiration' => 0)->json_is('/default_server_id' => undef);
  my $history = _history_count($id);
  $t->put_ok("$BASE/$id" => $SUPER => json => {})->status_is(200);
  is(_history_count($id), $history, 'empty update does not create history');
  $t->put_ok("$BASE/$id" => $SUPER => json => {username => "ua-admin-$pid"})->status_is(409);
  for my $input ({password => 'bad'}, {superuser => 'yes'}, {default_zone_id => $zone}, {closed => JSON::PP::true}) {
    $t->put_ok("$BASE/$id" => $SUPER => json => $input)->status_is(400);
  }
  $t->put_ok("$BASE/999999999" => $SUPER => json => {comment => 'missing'})->status_is(404);
};

subtest 'self-lockout and self-demotion are rejected' => sub {
  my $history = _history_count($super);
  for my $input ({superuser => JSON::PP::false}, {expiration => time - 1}, {expiration => time + 86400}) {
    $t->put_ok("$BASE/$super" => $SUPER => json => $input)->status_is(409);
  }
  $t->post_ok("$BASE/$super/lock" => $SUPER)->status_is(409);
  $t->post_ok("$BASE/$super/close" => $SUPER)->status_is(409);
  $t->delete_ok("$BASE/$super" => $SUPER)->status_is(409);
  is(_history_count($super), $history, 'failed changes do not create history');
  $t->get_ok("$BASE/$super" => $SUPER)->status_is(200)->json_is('/superuser' => JSON::PP::true)
    ->json_is('/locked' => JSON::PP::false);
};

subtest 'passwordless superusers qualify and role changes apply without revoking PATs' => sub {
  my $user = _legacy_passwordless(superuser => 1, email => "ua-second-admin-$pid\@example.com");
  my $id = $user->{id};
  my $pat = make_pat($id, 'second-admin');
  $t->reset_session;
  $t->put_ok("$BASE/$ordinary" => {Authorization => "Bearer $pat"} => json => {comment => 'Second administrator'})->status_is(200);
  $t->put_ok("$BASE/$id" => $SUPER => json => {superuser => JSON::PP::false})->status_is(200);
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {Authorization => "Bearer $pat"})->status_is(200)
    ->json_is('/user/superuser' => JSON::PP::false);
  $t->put_ok("$BASE/$ordinary" => {Authorization => "Bearer $pat"} => json => {comment => 'No longer administrator'})->status_is(403);
};

subtest 'locking, unlocking and password resets revoke credentials' => sub {
  my $user = _new(email => "ua-lock-$pid\@example.com", password => 'oldpass1');
  my $id = $user->{id};
  my ($pat, $session) = _credentials($id);
  $t->post_ok("$BASE/$id/lock" => $SUPER)->status_is(200)->json_is('/locked' => JSON::PP::true);
  _no_credentials($id);
  $t->post_ok("$BASE/$id/lock" => $SUPER)->status_is(409);
  $t->post_ok("$BASE/$id/password" => $SUPER => json => {password => 'newpass1'})->status_is(200)
    ->json_is('/locked' => JSON::PP::true);
  my $stored = _query('SELECT password FROM users WHERE id=?', $id)->[0][0];
  like($stored, qr/^LOCKED:/, 'reset preserves lock');
  $stored =~ s/^LOCKED://;
  is(Sauron::Util::pwd_check('newpass1', $stored), 0, 'reset password verifies');
  $t->post_ok("$BASE/$id/unlock" => $SUPER)->status_is(200)->json_is('/locked' => JSON::PP::false);
  $t->post_ok("$BASE/$id/unlock" => $SUPER)->status_is(409);
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {Authorization => "Bearer $pat"})->status_is(401);
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {Cookie => "bff_session=$session"})->status_is(401);
  _credentials($id);
  $t->post_ok("$BASE/$id/password" => $SUPER => json => {password => 'thirdpa3'})->status_is(200);
  _no_credentials($id);
  for my $input ({}, {password => ''}, {password => '123456789'}, {password => 'short', current_password => 'oldpass1'}) {
    $t->post_ok("$BASE/$id/password" => $SUPER => json => $input)->status_is(400);
  }
  my $passwordless = _legacy_passwordless;
  $t->post_ok("$BASE/$passwordless->{id}/lock" => $SUPER)->status_is(200);
  $t->post_ok("$BASE/$passwordless->{id}/unlock" => $SUPER)->status_is(200);
  ok(!defined _query('SELECT password FROM users WHERE id=?', $passwordless->{id})->[0][0], 'passwordless unlock stays passwordless');
};

subtest 'OIDC mode forbids local-password provisioning, not other administration' => sub {
  my $user = _new;
  local $t->app->config->{auth}{mode} = 'oidc';
  $t->post_ok($BASE => $SUPER => json => {username => "ua-oidc-denied-$pid", password => 'localpw1'})->status_is(403);
  $t->post_ok("$BASE/$user->{id}/password" => $SUPER => json => {password => 'localpw1'})->status_is(403);
  $t->post_ok($BASE => $SUPER => json => {username => "ua-oidc-denied-$pid"})->status_is(400);
  is(scalar @{_query('SELECT id FROM users WHERE username=?', "ua-oidc-denied-$pid")},
    0, 'OIDC creation cannot bypass the password requirement');
  $t->put_ok("$BASE/$user->{id}" => $SUPER => json => {comment => 'OIDC administration'})
    ->status_is(200);
  $t->post_ok("$BASE/$user->{id}/lock" => $SUPER)->status_is(200);
};

subtest 'all rule kinds, validation and inherited provenance' => sub {
  my $user = _new;
  my $id = $user->{id};
  my @rules = (
    {kind => 'group', group_id => $group}, {kind => 'server', server_id => $server, mode => 'RW'},
    {kind => 'zone', zone_id => $zone, mode => 'R'}, {kind => 'net', net_id => $net},
    {kind => 'hostmask', pattern => '^office-', zone_id => $zone},
    {kind => 'ipmask', pattern => '192.0.2.*'}, {kind => 'level', value => 50},
    {kind => 'elimit', value => 30}, {kind => 'defdept', value => '  IT  '},
    {kind => 'tmplmask', pattern => '^standard'}, {kind => 'grpmask', pattern => '^office'},
    {kind => 'delmask', pattern => '^retired'}, {kind => 'rhf', field => 'dept', required => JSON::PP::true},
    {kind => 'flag', value => 'cname'}, {kind => 'defhost', value => ' host%{id} '},
  );
  my @rule_ids;
  for my $rule (@rules) {
    $t->post_ok("$BASE/$id/rights" => $SUPER => json => $rule)->status_is(201)
      ->json_is('/kind' => $rule->{kind})->json_is('/source' => 'direct');
    push @rule_ids, $t->tx->res->json->{id};
    $t->post_ok("$BASE/$id/rights" => $SUPER => json => $rule)->status_is(409);
  }
  my $inherited = Sauron::BackEnd::add_record('user_rights', {type => 1, ref => $group, rtype => 1, rref => $server, rule => 'RW'});
  $t->get_ok("$BASE/$id/rights?per_page=100" => $SUPER)->status_is(200)
    ->json_is('/metadata/pagination/total' => 16);
  my $items = $t->tx->res->json->{data};
  my ($source) = grep { $_->{id} == $inherited } @$items;
  is($source->{source}, 'inherited', 'group-owned rule identified');
  is($source->{source_group_id}, $group, 'source group ID');
  is($source->{source_group_name}, "ua-group-$pid", 'source group name');
  is((grep { $_->{kind} eq 'defdept' } @$items)[0]{value}, 'IT', 'department trimmed');
  is((grep { $_->{kind} eq 'defhost' } @$items)[0]{value}, 'host%{id}', 'hostname whitespace removed');
  is((grep { $_->{kind} eq 'flag' } @$items)[0]{value}, 'CNAME', 'flag uppercased');
  is((grep { $_->{kind} eq 'rhf' } @$items)[0]{required}, JSON::PP::true, 'required field boolean');
  $t->get_ok("$BASE/$id/rights?page=2&per_page=5" => $SUPER)->status_is(200)
    ->json_is('/metadata/pagination/total_pages' => 4);
  $t->delete_ok("$BASE/$id/rights/$inherited" => $SUPER)->status_is(404);
  $t->delete_ok("$BASE/$ordinary/rights/$rule_ids[1]" => $SUPER)->status_is(404);
  $t->delete_ok("$BASE/$id/rights/$rule_ids[1]" => $SUPER)->status_is(204);
  $t->get_ok("$BASE/$id/rights?per_page=100" => $SUPER)->status_is(200)
    ->json_is('/metadata/pagination/total' => 15);
  for my $rule (
    {kind => 'unknown', value => 'x'}, {kind => 'level', value => 1000},
    {kind => 'server', server_id => $server, mode => 'X'}, {kind => 'group', group_id => 999999999},
    {kind => 'hostmask', pattern => '['}, {kind => 'ipmask', pattern => 'invalid'},
    {kind => 'rhf', field => 'username', required => JSON::PP::true},
    {kind => 'defhost', value => 'no-placeholder'}, {kind => 'flag', value => 'INVALID'},
    {kind => 'defdept', value => '   '}, {kind => 'elimit', value => -1},
    {kind => 'tmplmask', pattern => 'x' x 81}, {kind => 'level', value => 1, rref => -1}
  ) {
    $t->post_ok("$BASE/$id/rights" => $SUPER => json => $rule)->status_is(400);
  }
  for my $query ('page=0', 'per_page=101', 'unknown=x', 'sort=id') {
    $t->get_ok("$BASE/$id/rights?$query" => $SUPER)->status_is(400);
  }
  my ($pat) = _credentials($id);
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {Authorization => "Bearer $pat"})->status_is(200)
    ->json_is("/permissions/server/$server" => 'RW');
  my $self_rights = $t->tx->res->json->{rights};
  is(scalar @$self_rights, 15, 'self view includes every remaining rule kind');
  is_deeply((grep { $_->{id} == $inherited } @$self_rights)[0], $source,
    'self view preserves inherited group provenance');
  is((grep { $_->{kind} eq 'net' } @$self_rights)[0]{net_id}, $net, 'self view includes networks');
  is((grep { $_->{kind} eq 'elimit' } @$self_rights)[0]{value}, 30, 'self view includes expiration limit');
  is((grep { $_->{kind} eq 'flag' } @$self_rights)[0]{value}, 'CNAME', 'self view includes privilege flags');
  $t->get_ok("$BASE/$id/rights" => {Authorization => "Bearer $pat"})->status_is(403);
  $t->get_ok("$BASE/$ordinary/rights" => {Authorization => "Bearer $pat"})->status_is(403);
  $t->put_ok('/api/v1/auth/me' => {Authorization => "Bearer $pat"} => json => {rights => []})->status_is(400);
  $t->get_ok('/api/v1/auth/me' => $ORD)->status_is(200)->json_is('/rights' => []);
  $t->get_ok("/api/v1/auth/me?id=$ordinary" => {Authorization => "Bearer $pat"})
    ->status_is(200)->json_is('/rights' => $self_rights);
  $t->delete_ok("$BASE/$id/rights" => $SUPER)->status_is(204);
  $t->get_ok("$BASE/$id/rights" => $SUPER)->status_is(200)->json_is('/metadata/pagination/total' => 0);
  ok(@{_query('SELECT id FROM user_rights WHERE id=?', $inherited)}, 'group-owned rule preserved');
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {Authorization => "Bearer $pat"})->status_is(200)
    ->json_is('/permissions/server' => {})->json_is('/rights' => []);
};

subtest 'self permission rules are complete rather than limited to a list page' => sub {
  my $user = _new;
  my $id = $user->{id};
  _query("INSERT INTO user_rights (type,ref,rtype,rref,rule) "
    . "SELECT 2,?,4,-1,'^host-' || n FROM generate_series(1,105) n RETURNING id", $id);
  $t->get_ok("$BASE/$id/rights" => $SUPER)->status_is(200)
    ->json_is('/metadata/pagination/total' => 105);
  is(scalar @{$t->tx->res->json->{data}}, 50, 'administrative list remains paginated');
  my $pat = make_pat($id, 'all-own-rights');
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {Authorization => "Bearer $pat"})->status_is(200);
  is(scalar @{$t->tx->res->json->{rights}}, 105, 'all own rules returned');
  $t->json_is('/rights/104/pattern' => '^host-105');
};

subtest 'group lookup is paginated read-only reference data' => sub {
  $t->get_ok('/api/v1/user-groups?per_page=100' => $SUPER)->status_is(200);
  my ($found) = grep { $_->{id} == $group } @{$t->tx->res->json->{data}};
  is($found->{name}, "ua-group-$pid", 'existing group discoverable');
  is($found->{comment}, 'Membership reference', 'group comment');
  for my $query ('page=0', 'per_page=101', 'unknown=x', 'sort=name') {
    $t->get_ok("/api/v1/user-groups?$query" => $SUPER)->status_is(400);
  }
  $t->post_ok('/api/v1/user-groups' => $SUPER => json => {name => 'denied'})->status_is(404);
};

subtest 'closure is terminal and deletion is explicit' => sub {
  my $user = _new(name => 'Personal name', comment => 'Personal details', email => "ua-close-$pid\@example.com");
  my $id = $user->{id};
  $t->post_ok("$BASE/$id/close" => $SUPER)->status_is(409);
  $t->delete_ok("$BASE/$id" => $SUPER)->status_is(409);
  $t->post_ok("$BASE/$id/rights" => $SUPER => json => {kind => 'group', group_id => $group})->status_is(201);
  _credentials($id);
  $t->post_ok("$BASE/$id/lock" => $SUPER)->status_is(200);
  $t->post_ok("$BASE/$id/close" => $SUPER)->status_is(200)->json_is('/closed' => JSON::PP::true)
    ->json_is('/locked' => JSON::PP::true)->json_is('/username' => $user->{username})
    ->json_is('/name' => 'Removed User')->json_is('/email' => undef)->json_is('/comment' => undef)
    ->json_is('/muser' => "ua-admin-$pid");
  _no_credentials($id);
  $t->get_ok("$BASE/$id/rights" => $SUPER)->status_is(200)->json_is('/metadata/pagination/total' => 0);
  for my $action (qw(unlock lock close)) {
    $t->post_ok("$BASE/$id/$action" => $SUPER)->status_is(409);
  }
  $t->put_ok("$BASE/$id" => $SUPER => json => {name => 'Reopen'})->status_is(409);
  $t->post_ok("$BASE/$id/password" => $SUPER => json => {password => 'reopen1'})->status_is(409);
  $t->post_ok("$BASE/$id/rights" => $SUPER => json => {kind => 'level', value => 1})->status_is(409);
  $t->delete_ok("$BASE/$id/rights" => $SUPER)->status_is(409);
  $t->delete_ok("$BASE/$id" => $SUPER)->status_is(204);
  $t->get_ok("$BASE/$id" => $SUPER)->status_is(404);
  my $events = _query('SELECT uid,action FROM history WHERE type=5 AND ref=? ORDER BY id', $id);
  ok((grep { $_->[1] =~ /^ANONYMIZE/ && $_->[0] == $super } @$events), 'closure attributed to actor');
  ok((grep { $_->[1] =~ /^DELETE/ && $_->[0] == $super } @$events), 'deletion history retained');
  my $expired = _new(expiration => time - 1);
  $t->delete_ok("$BASE/$expired->{id}" => $SUPER)->status_is(204);
};

subtest 'passwordless expiration is enforced for proxy, session and PAT authentication' => sub {
  my $email = "ua-expiry-$pid\@example.com";
  my $user = _legacy_passwordless(email => $email);
  my $id = $user->{id};
  my ($pat, $session) = _credentials($id);
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {'X-Remote-User' => $email})->status_is(200);
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {Cookie => "bff_session=$session"})->status_is(200);
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {Authorization => "Bearer $pat"})->status_is(200);
  $t->put_ok("$BASE/$id" => $SUPER => json => {expiration => time - 1})->status_is(200);
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {'X-Remote-User' => $email})->status_is(403);
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {Cookie => "bff_session=$session"})->status_is(401);
  $t->reset_session;
  $t->get_ok('/api/v1/auth/me' => {Authorization => "Bearer $pat"})->status_is(401);
};

subtest 'audit failures roll back account, rights and credential changes' => sub {
  my $user = _new(password => 'oldpass1');
  my $id = $user->{id};
  _credentials($id);
  my $history = _history_count($id);
  my $expired = _new(expiration => time - 1);
  my $expired_id = $expired->{id};
  _credentials($expired_id);
  $t->post_ok("$BASE/$expired_id/rights" => $SUPER => json => {kind => 'group', group_id => $group})->status_is(201);
  is(Sauron::DB::db_exec("CREATE FUNCTION pg_temp.$trigger() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN IF NEW.uid=$super AND NEW.type=5 THEN RAISE EXCEPTION 'audit unavailable'; END IF; RETURN NEW; END \$\$"), 0, 'audit failure function');
  is(Sauron::DB::db_exec("CREATE TRIGGER $trigger BEFORE INSERT ON history FOR EACH ROW EXECUTE FUNCTION pg_temp.$trigger()"), 0, 'audit failure trigger');
  $t->put_ok("$BASE/$id" => $SUPER => json => {comment => 'must roll back'})->status_is(500);
  $t->post_ok("$BASE/$id/rights" => $SUPER => json => {kind => 'level', value => 1})->status_is(500);
  $t->post_ok("$BASE/$id/password" => $SUPER => json => {password => 'newpass1'})->status_is(500);
  $t->post_ok("$BASE/$id/lock" => $SUPER)->status_is(500);
  $t->post_ok("$BASE/$expired_id/close" => $SUPER)->status_is(500);
  $t->delete_ok("$BASE/$expired_id" => $SUPER)->status_is(500);
  $t->post_ok($BASE => $SUPER => json => {username => "ua-rollback-$pid", password => 'testpass'})->status_is(500);
  is(Sauron::DB::db_exec("DROP TRIGGER $trigger ON history"), 0, 'remove audit failure trigger');
  is(scalar @{_query('SELECT id FROM users WHERE username=?', "ua-rollback-$pid")}, 0, 'failed creation rolled back');
  $t->get_ok("$BASE/$expired_id" => $SUPER)->status_is(200)->json_is('/closed' => JSON::PP::false);
  is(_query('SELECT COUNT(*) FROM user_rights WHERE type=2 AND ref=?', $expired_id)->[0][0], 1, 'closure and deletion preserve rights on failure');
  is(_query('SELECT COUNT(*) FROM personal_access_tokens WHERE user_id=?', $expired_id)->[0][0], 1, 'failed removal preserves PATs');
  is(_query('SELECT COUNT(*) FROM bff_sessions WHERE user_id=?', $expired_id)->[0][0], 1, 'failed removal preserves sessions');
  $t->get_ok("$BASE/$id" => $SUPER)->status_is(200)->json_is('/comment' => undef)->json_is('/locked' => JSON::PP::false);
  is(_query('SELECT COUNT(*) FROM user_rights WHERE type=2 AND ref=?', $id)->[0][0], 0, 'failed grant rolled back');
  is(_query('SELECT COUNT(*) FROM personal_access_tokens WHERE user_id=?', $id)->[0][0], 1, 'PAT revocation rolled back');
  is(_query('SELECT COUNT(*) FROM bff_sessions WHERE user_id=?', $id)->[0][0], 1, 'session revocation rolled back');
  is(Sauron::Util::pwd_check('oldpass1', _query('SELECT password FROM users WHERE id=?', $id)->[0][0]), 0, 'password reset rolled back');
  is(_history_count($id), $history, 'no false success history');
};

subtest 'initial grant and grant-audit failures roll back the entire creation' => sub {
  my $before = _query('SELECT COUNT(*) FROM user_rights WHERE (rtype=1 AND rref=?) OR (rtype=2 AND rref=?)',
    $server, $zone)->[0][0];
  for my $table (qw(user_rights history)) {
    my $name = "ua-initial-$table-$pid";
    $name =~ tr/_/-/;
    my $failure = "reject_initial_${table}_$pid";
    my $condition = $table eq 'history'
      ? "NEW.uid=$super AND NEW.type=5 AND NEW.action='ADD: User right'"
      : "NEW.type=2 AND NEW.rtype=2 AND NEW.rref=$zone";
    is(Sauron::DB::db_exec("CREATE FUNCTION pg_temp.$failure() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN IF $condition THEN RAISE EXCEPTION 'initial grant unavailable'; END IF; RETURN NEW; END \$\$"),
      0, 'initial grant failure function');
    is(Sauron::DB::db_exec("CREATE TRIGGER $failure BEFORE INSERT ON $table FOR EACH ROW EXECUTE FUNCTION pg_temp.$failure()"),
      0, 'initial grant failure trigger');
    $t->post_ok($BASE => $SUPER => json => {
      username => $name, password => 'testpass', default_server_id => $server, default_zone_id => $zone,
    })->status_is(500);
    is(Sauron::DB::db_exec("DROP TRIGGER $failure ON $table"), 0, 'remove failure trigger');
    my $rows = _query('SELECT id FROM users WHERE username=?', $name);
    push @users, map { $_->[0] } @$rows;
    is(scalar @$rows, 0, 'account creation rolled back');
    is(_query('SELECT COUNT(*) FROM history WHERE uid=? AND type=5 AND info LIKE ?', $super, "%$name%")
      ->[0][0], 0, 'account and grant history rolled back');
    is(_query('SELECT COUNT(*) FROM user_rights WHERE (rtype=1 AND rref=?) OR (rtype=2 AND rref=?)',
      $server, $zone)->[0][0], $before, 'no orphaned initial grants');
  }
};

subtest 'administrative history excludes credentials' => sub {
  my $user = _new(password => 'secret12');
  $t->post_ok("$BASE/$user->{id}/password" => $SUPER => json => {password => 'secret34'})->status_is(200);
  my $events = _query('SELECT uid,info FROM history WHERE type=5 AND ref=?', $user->{id});
  is(scalar @$events, 2, 'create and reset audited');
  for my $event (@$events) {
    is($event->[0], $super, 'correct actor ID');
    unlike($event->[1], qr/secret12|secret34|CRYPT:|MD5:/, 'no password or hash in history');
  }
};

done_testing;
