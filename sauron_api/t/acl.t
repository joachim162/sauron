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

sub _cleanup_fixtures {
  for my $sid (@servers) {
    eval {
      Sauron::DB::db_exec(
        "DELETE FROM cidr_entries WHERE type=0 AND ref IN (SELECT id FROM acls WHERE server=$sid)");
      Sauron::DB::db_exec("DELETE FROM keys WHERE type=1 AND ref=$sid");
      Sauron::DB::db_exec("DELETE FROM acls WHERE server=$sid");
    };
  }
}

END {
  _cleanup_fixtures();
  for my $uid (@users) {
    eval { delete_test_user($uid); };
  }
  for my $sid (@servers) {
    eval { delete_test_server($sid); };
  }
}

my $srv  = create_test_server(name => "srv-acl-${pid}",  comment => 'ACL CRUD test');
my $srv2 = create_test_server(name => "srv-acl2-${pid}", comment => 'ACL cross-server test');
push @servers, $srv, $srv2;

my $super  = create_test_user(username => "aclsuper_${pid}", email => "aclsuper_${pid}\@example.com", superuser => 1);
my $level5 = create_test_user(username => "acllvl_${pid}",   email => "acllvl_${pid}\@example.com");
my $low    = create_test_user(username => "acllow_${pid}",   email => "acllow_${pid}\@example.com");
my $rw     = create_test_user(username => "aclrw_${pid}",    email => "aclrw_${pid}\@example.com");
push @users, $super, $level5, $low, $rw;

grant_server_access($level5, $srv, 'R');
grant_server_access($low,    $srv, 'R');
grant_server_access($rw,     $srv, 'RW');

# level5 user: authorization level 5 (ALEVEL_ACLS)
Sauron::BackEnd::add_record('user_rights', {
  type => 2, ref => $level5, rtype => 6, rref => 0, rule => 5,
});

# TSIG key fixtures (type=1, ref=server) — proper lifecycle is keygen's; the
# API only ever reads these.
Sauron::BackEnd::set_muser('test');
my $key_id = Sauron::BackEnd::add_record('keys', {
  type => 1, ref => $srv, name => "xfer-key-${pid}",
  keytype => 0, nametype => 0, protocol => 2, algorithm => 159,
  mode => 0, keysize => 128, comment => 'fixture key',
});
die "Failed to create key fixture: $key_id" unless $key_id > 0;
my $other_key_id = Sauron::BackEnd::add_record('keys', {
  type => 1, ref => $srv2, name => "other-key-${pid}",
  keytype => 0, nametype => 0, protocol => 2, algorithm => 157,
  mode => 0, keysize => 128, comment => 'foreign fixture key',
});
die "Failed to create foreign key fixture: $other_key_id" unless $other_key_id > 0;
# Extra TSIG fixture (158) and a non-HMAC key (algorithm 1, #55) on $srv.
my $sha1_key_id = Sauron::BackEnd::add_record('keys', {
  type => 1, ref => $srv, name => "sha1-key-${pid}",
  keytype => 0, nametype => 0, protocol => 2, algorithm => 158,
  mode => 0, keysize => 128, comment => 'fixture HMAC-SHA1 key',
});
die "Failed to create sha1 key fixture: $sha1_key_id" unless $sha1_key_id > 0;
my $rsa_key_id = Sauron::BackEnd::add_record('keys', {
  type => 1, ref => $srv, name => "rsa-key-${pid}",
  keytype => 0, nametype => 0, protocol => 2, algorithm => 1,
  mode => 0, keysize => 128, comment => 'fixture non-HMAC key',
});
die "Failed to create rsa key fixture: $rsa_key_id" unless $rsa_key_id > 0;

# ACL fixture on another server, for cross-server member rejection.
my $other_acl_id = Sauron::BackEnd::add_acl({
  server => $srv2, name => "other-acl-${pid}",
});
die "Failed to create foreign ACL fixture: $other_acl_id" unless $other_acl_id > 0;

sub _hdr {
  my ($name) = @_;
  $t->reset_session;
  return { 'X-Remote-User' => $name };
}
my $SUPER  = _hdr("aclsuper_${pid}\@example.com");
my $LEVEL5 = _hdr("acllvl_${pid}\@example.com");
my $LOW    = _hdr("acllow_${pid}\@example.com");
my $RW     = _hdr("aclrw_${pid}\@example.com");

my $BASE = "/api/v1/servers/srv-acl-${pid}/acls";
my $KEYS = "/api/v1/servers/srv-acl-${pid}/keys";
my $ACL  = "internal-${pid}";
my $ACL_ID;

# ========================================================================
# CREATE
# ========================================================================

subtest 'POST create ACL (full payload with mixed members)' => sub {
  $t->post_ok($BASE => $SUPER => json => {
    name    => $ACL,
    comment => 'Created by acl.t',
    acl     => [
      { mode => 0, ip => '10.0.0.0/8',   op => 0, comment => 'corp' },
      { mode => 0, ip => '10.20.0.0/16', op => 1, comment => 'NOT guest' },
      { mode => 1, acl => 1,             op => 0, comment => 'builtin any' },
      { mode => 2, tkey => $key_id,      op => 0, comment => 'transfer key' },
    ],
  })->status_is(201)->json_has('/id')->json_has('/server_id');

  my $j = $t->tx->res->json;
  is($j->{name},     $ACL,      'name');
  is($j->{comment},  'Created by acl.t', 'comment');
  is($j->{server_id}, $srv,     'server_id');
  ok(!$j->{builtin}, 'builtin false for server ACL');
  is($j->{ref_count}, 0,        'ref_count 0 for unreferenced ACL');
  ok($j->{cuser},    'audit cuser present');
  $ACL_ID = $j->{id};

  my $els = $j->{acl};
  is(scalar @$els, 4, 'four members');
  is($els->[0]{mode}, 0,            'member 1 mode CIDR');
  is($els->[0]{ip}, '10.0.0.0/8',   'member 1 ip');
  is($els->[0]{op}, 0,              'member 1 op allow');
  is($els->[0]{comment}, 'corp',    'member 1 comment');
  is($els->[1]{op}, 1,              'member 2 op NOT');
  is($els->[2]{mode}, 1,            'member 3 mode ACL');
  is($els->[2]{acl}, 1,             'member 3 built-in reference');
  ok(!defined $els->[2]{ip},        'member 3 ip null');
  is($els->[3]{mode}, 2,            'member 4 mode key');
  is($els->[3]{tkey}, $key_id,      'member 4 key id');
  ok(!defined $els->[3]{ip},        'member 4 ip null');
};

subtest 'POST create ACL - name validation' => sub {
  $t->post_ok($BASE => $SUPER => json => { comment => 'x' })->status_is(400);
  $t->post_ok($BASE => $SUPER => json => { name => "bad name!-${pid}" })
    ->status_is(400)->json_like('/message' => qr/match/);
};

subtest 'POST create ACL - member validation' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => 'nope' })
    ->status_is(400);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => ['nope'] })
    ->status_is(400);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ ip => '10.0.0.0/8' }] })
    ->status_is(400)->json_like('/message' => qr/mode/);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ mode => 3, ip => '10.0.0.0/8' }] })
    ->status_is(400);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ mode => 0 }] })
    ->status_is(400)->json_like('/message' => qr/ip/);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ mode => 0, ip => 'not-a-cidr' }] })
    ->status_is(400)->json_like('/message' => qr/ip/);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ mode => 1 }] })
    ->status_is(400)->json_like('/message' => qr/acl/);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ mode => 1, acl => 99999 }] })
    ->status_is(400)->json_like('/message' => qr/not found/);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ mode => 1, acl => $other_acl_id }] })
    ->status_is(400)->json_like('/message' => qr/not found/);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ mode => 2 }] })
    ->status_is(400)->json_like('/message' => qr/tkey/);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ mode => 2, tkey => 99999 }] })
    ->status_is(400)->json_like('/message' => qr/not a key/);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ mode => 2, tkey => $other_key_id }] })
    ->status_is(400)->json_like('/message' => qr/not a key/);
  # mode=2 must reject non-HMAC keys on this server (issue #55).
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ mode => 2, tkey => $rsa_key_id }] })
    ->status_is(400)->json_like('/message' => qr/TSIG\/HMAC-family/);
  $t->post_ok($BASE => $SUPER => json => { name => "v1-${pid}", acl => [{ mode => 0, ip => '10.0.0.0/8', op => 2 }] })
    ->status_is(400);
};

subtest 'POST create ACL - duplicate name returns 409' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => $ACL })
    ->status_is(409)->json_is('/error' => 'Conflict');
};

# ========================================================================
# LIST
# ========================================================================

subtest 'GET list - envelope, built-ins, summary shape' => sub {
  $t->get_ok($BASE => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  ok(ref $j->{data} eq 'ARRAY' && exists $j->{metadata}, 'paginated envelope');

  my %by_name = map { $_->{name} => $_ } @{$j->{data}};
  my ($own) = grep { $_->{name} eq $ACL } @{$j->{data}};
  ok($own, 'created ACL present');
  ok(!$own->{builtin}, 'own ACL builtin false');
  is($own->{server_id}, $srv, 'summary server_id');
  ok(exists $own->{cuser}, 'summary carries audit fields');
  ok(!exists $own->{acl}, 'summary omits member array');

  for my $builtin (qw(any none localhost localnets)) {
    ok($by_name{$builtin}, "built-in $builtin listed");
    ok($by_name{$builtin}{builtin}, "built-in $builtin has builtin flag true");
    is($by_name{$builtin}{server_id}, -1, "built-in $builtin server_id is -1");
  }
};

subtest 'GET list - filters and sort' => sub {
  $t->get_ok("$BASE?name=^$ACL\$" => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  is(scalar @{$j->{data}}, 1,                          'name filter narrows to one');
  is($j->{data}[0]{name},  $ACL,                       'name filter matches');

  $t->get_ok("$BASE?comment=built" => $SUPER)->status_is(200);

  $t->get_ok("$BASE?sort=comment:desc" => $SUPER)->status_is(200);
  my @comments = map { $_->{comment} // '' } @{$t->tx->res->json->{data}};
  my @sorted = sort { $b cmp $a } @comments;
  is_deeply(\@comments, \@sorted, 'sorted by comment desc');

  $t->get_ok("$BASE?bogus=1" => $SUPER)->status_is(400);
  $t->get_ok("$BASE?sort=nope" => $SUPER)->status_is(400);
  $t->get_ok("$BASE?per_page=101" => $SUPER)->status_is(400);
  $t->get_ok("$BASE?page=0" => $SUPER)->status_is(400);
  $t->get_ok("$BASE?name=%28" => $SUPER)->status_is(400);
};

# ========================================================================
# DETAIL
# ========================================================================

subtest 'GET detail - full object with members and ref_count' => sub {
  $t->get_ok("$BASE/$ACL" => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  for my $k (qw(acl ref_count cdate cuser mdate muser)) {
    ok(exists $j->{$k}, "detail has $k");
  }
};

subtest 'GET detail - built-in and unknown are 404' => sub {
  $t->get_ok("$BASE/any" => $SUPER)->status_is(404);
  $t->get_ok("$BASE/nope-${pid}" => $SUPER)->status_is(404)->json_is('/error' => 'Not Found');
};

subtest 'GET detail - dotted name is addressable (relaxed placeholder)' => sub {
  my $dotted = "dotted.${pid}.acl";
  $t->post_ok($BASE => $SUPER => json => { name => $dotted })->status_is(201);
  $t->get_ok("$BASE/$dotted" => $SUPER)->status_is(200)->json_is('/name' => $dotted);

  my $dotted_id = $t->tx->res->json->{id};
  $t->get_ok("$BASE/$dotted" => $SUPER)->status_is(200);

  # self-reference rejected on PUT (own id < nothing lower yet)
  $t->put_ok("$BASE/$dotted" => $SUPER => json => { acl => [{ mode => 1, acl => $dotted_id }] })
    ->status_is(400)->json_like('/message' => qr/nested references/);

  $t->delete_ok("$BASE/$dotted" => $SUPER)->status_is(204);
};

# ========================================================================
# UPDATE
# ========================================================================

subtest 'PUT update - partial update preserves members' => sub {
  $t->put_ok("$BASE/$ACL" => $SUPER => json => { comment => 'updated comment' })
    ->status_is(200)->json_is('/comment' => 'updated comment');
  my $j = $t->tx->res->json;
  is(scalar @{$j->{acl}}, 4, 'members preserved');
  is($j->{acl}[3]{tkey}, $key_id, 'key member preserved');
};

subtest 'PUT update - members use replace-all semantics' => sub {
  $t->put_ok("$BASE/$ACL" => $SUPER => json => {
    acl => [{ mode => 1, acl => 1, comment => 'r1' }],
  })->status_is(200);
  is_deeply(
    $t->tx->res->json->{acl},
    [{ mode => 1, acl => 1, ip => undef, tkey => 0, op => 0, comment => 'r1' }],
    'members replaced'
  );
};

subtest 'PUT update - empty member array allowed' => sub {
  $t->put_ok("$BASE/$ACL" => $SUPER => json => { acl => [] })->status_is(200);
  is_deeply($t->tx->res->json->{acl}, [], 'members cleared');
};

subtest 'PUT update - rename changes the URL' => sub {
  $t->put_ok("$BASE/$ACL" => $SUPER => json => { name => "renamed-${pid}" })
    ->status_is(200)->json_is('/name' => "renamed-${pid}");
  $t->get_ok("$BASE/$ACL" => $SUPER)->status_is(404);
  $t->get_ok("$BASE/renamed-${pid}" => $SUPER)->status_is(200);

  $t->put_ok("$BASE/renamed-${pid}" => $SUPER => json => { name => $ACL })->status_is(200);
};

subtest 'PUT update - duplicate rename returns 409' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => "other-${pid}" })->status_is(201);
  $t->put_ok("$BASE/other-${pid}" => $SUPER => json => { name => $ACL })->status_is(409);

  $t->put_ok("$BASE/other-${pid}" => $SUPER => json => { name => "bad name!" })->status_is(400);
};

subtest 'PUT update - 404 for unknown' => sub {
  $t->put_ok("$BASE/nope-${pid}" => $SUPER => json => { comment => 'x' })->status_is(404);
};

# ========================================================================
# NESTED ACL ACYCLICITY
# ========================================================================

subtest 'nested ACL references - acyclicity on PUT' => sub {
  $t->post_ok($BASE => $SUPER => json => {
    name => "nested-${pid}",
    acl  => [{ mode => 1, acl => $ACL_ID, comment => 'inner' }],
  })->status_is(201);
  my $nested_id = $t->tx->res->json->{id};
  ok($nested_id > $ACL_ID, 'nested ACL gets a higher id');

  # self-reference on the nested ACL
  $t->put_ok("$BASE/nested-${pid}" => $SUPER => json => { acl => [{ mode => 1, acl => $nested_id }] })
    ->status_is(400)->json_like('/message' => qr/nested references/);

  # forward reference: inner (lower id) pointing at nested (higher id)
  $t->put_ok("$BASE/$ACL" => $SUPER => json => { acl => [{ mode => 1, acl => $nested_id }] })
    ->status_is(400)->json_like('/message' => qr/nested references/);
};

# ========================================================================
# DELETE / reassign_to
# ========================================================================

subtest 'DELETE - invalid reassign_to' => sub {
  $t->delete_ok("$BASE/$ACL?reassign_to=$ACL_ID" => $SUPER)->status_is(400);
  $t->delete_ok("$BASE/$ACL?reassign_to=99999" => $SUPER)->status_is(400);
  $t->delete_ok("$BASE/$ACL?reassign_to=$other_acl_id" => $SUPER)->status_is(400);
};

subtest 'DELETE - unreferenced ACL' => sub {
  $t->delete_ok("$BASE/other-${pid}" => $SUPER)->status_is(204);
  $t->get_ok("$BASE/other-${pid}" => $SUPER)->status_is(404);
};

subtest 'DELETE - reassign moves nested references (type=0, issue #53 fix)' => sub {
  # victim -> referenced from nested2
  $t->post_ok($BASE => $SUPER => json => { name => "victim-${pid}", acl => [{ mode => 0, ip => '192.0.2.0/24' }] })
    ->status_is(201);
  my $victim_id = $t->tx->res->json->{id};

  $t->post_ok($BASE => $SUPER => json => {
    name => "nested2-${pid}",
    acl  => [{ mode => 1, acl => $victim_id, comment => 'points at victim' }],
  })->status_is(201);
  my $nested2_id = $t->tx->res->json->{id};

  $t->get_ok("$BASE/victim-${pid}" => $SUPER)->status_is(200);
  is($t->tx->res->json->{ref_count}, 1, 'victim referenced once');

  $t->delete_ok("$BASE/victim-${pid}?reassign_to=$ACL_ID" => $SUPER)->status_is(204);
  $t->get_ok("$BASE/victim-${pid}" => $SUPER)->status_is(404);

  $t->get_ok("$BASE/nested2-${pid}" => $SUPER)->status_is(200);
  is_deeply(
    $t->tx->res->json->{acl},
    [{ mode => 1, acl => $ACL_ID, ip => undef, tkey => 0, op => 0, comment => 'points at victim' }],
    'nested reference reassigned to the replacement ACL'
  );
};

subtest 'DELETE - omitting reassign_to detaches references (acl=-1)' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => "victim2-${pid}" })->status_is(201);
  my $victim2_id = $t->tx->res->json->{id};

  $t->post_ok($BASE => $SUPER => json => {
    name => "nested3-${pid}",
    acl  => [{ mode => 1, acl => $victim2_id, comment => 'points at victim2' }],
  })->status_is(201);

  $t->delete_ok("$BASE/victim2-${pid}" => $SUPER)->status_is(204);

  $t->get_ok("$BASE/nested3-${pid}" => $SUPER)->status_is(200);
  is_deeply(
    $t->tx->res->json->{acl},
    [{ mode => 1, acl => -1, ip => undef, tkey => 0, op => 0, comment => 'points at victim2' }],
    'nested reference detached (acl=-1)'
  );
};

subtest 'DELETE - server-level (type>0) references are reassigned too' => sub {
  $t->post_ok($BASE => $SUPER => json => { name => "victim3-${pid}" })->status_is(201);
  my $victim3_id = $t->tx->res->json->{id};

  # Simulate a server allow-transfer rule referencing the ACL (type=1).
  Sauron::DB::db_exec(
    "INSERT INTO cidr_entries (mode,ip,acl,tkey,op,comment,type,ref) " .
    "VALUES (1,NULL,$victim3_id,-1,0,'type1-${pid}',1,$srv)");

  $t->delete_ok("$BASE/victim3-${pid}?reassign_to=1" => $SUPER)->status_is(204);

  my @q;
  Sauron::DB::db_query(
    "SELECT acl FROM cidr_entries WHERE type=1 AND ref=$srv AND comment='type1-${pid}'", \@q);
  is(scalar @q, 1, 'server-level row survives');
  is($q[0][0],     1, 'server-level reference moved to the built-in ACL');
};

subtest 'DELETE - reassign must not create a cyclic/self reference (issue #54)' => sub {
  $t->post_ok($BASE => $SUPER => json => {
    name => "cyc-victim-${pid}", acl => [{ mode => 0, ip => '198.51.100.0/24' }],
  })->status_is(201);
  my $victim_id = $t->tx->res->json->{id};

  $t->post_ok($BASE => $SUPER => json => {
    name => "cyc-ref-${pid}", acl => [{ mode => 1, acl => $victim_id }],
  })->status_is(201);
  my $referent_id = $t->tx->res->json->{id};

  # reassign to the ACL that references the victim -> would become a self-reference
  $t->delete_ok("$BASE/cyc-victim-${pid}?reassign_to=$referent_id" => $SUPER)
    ->status_is(400)->json_like('/message' => qr/created before|built-in/);

  # a newer ACL that doesn't reference the victim is still rejected (id rule)
  $t->post_ok($BASE => $SUPER => json => { name => "cyc-newer-${pid}" })->status_is(201);
  my $newer_id = $t->tx->res->json->{id};
  $t->delete_ok("$BASE/cyc-victim-${pid}?reassign_to=$newer_id" => $SUPER)->status_is(400);

  # built-in target is allowed; the reference moves, no cycle
  $t->delete_ok("$BASE/cyc-victim-${pid}?reassign_to=1" => $SUPER)->status_is(204);
  $t->get_ok("$BASE/cyc-ref-${pid}" => $SUPER)->status_is(200);
  is($t->tx->res->json->{acl}[0]{acl}, 1, 'reference moved to built-in, no cycle');
};

subtest 'DELETE - 404 for unknown' => sub {
  $t->delete_ok("$BASE/nope-${pid}" => $SUPER)->status_is(404);
};

# ========================================================================
# AUTHORIZATION
# ========================================================================

subtest 'read requires server R + ALEVEL_ACLS' => sub {
  $t->get_ok($BASE => $LOW)->status_is(403);
  $t->get_ok("$BASE/$ACL" => $LOW)->status_is(403);
};

subtest 'level >= ALEVEL_ACLS with server R can read' => sub {
  $t->get_ok($BASE => $LEVEL5)->status_is(200);
  $t->get_ok("$BASE/$ACL" => $LEVEL5)->status_is(200)->json_is('/name' => $ACL);
};

subtest 'writes require superuser' => sub {
  $t->post_ok($BASE => $RW => json => { name => "rw-${pid}" })
    ->status_is(403)->json_is('/error' => 'Forbidden');
  $t->put_ok("$BASE/$ACL" => $RW => json => { comment => 'x' })->status_is(403);
  $t->delete_ok("$BASE/nested-${pid}" => $RW)->status_is(403);
};

# ========================================================================
# KEYS (read-only companion, legacy browse_keys parity)
# ========================================================================

subtest 'GET keys - envelope with fixture key' => sub {
  $t->get_ok($KEYS => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  ok(ref $j->{data} eq 'ARRAY' && exists $j->{metadata}, 'paginated envelope');

  my ($key) = grep { $_->{id} == $key_id } @{$j->{data}};
  ok($key, 'fixture key listed');
  is($key->{name},      "xfer-key-${pid}", 'key name');
  is($key->{algorithm}, 159,               'key algorithm');
  is($key->{keysize},   128,               'key keysize');
  is($key->{mode},      0,                 'key mode');
  is($key->{server_id}, $srv,              'key server_id');
  ok(!exists $key->{secretkey}, 'no secret key material');
  ok(!exists $key->{publickey}, 'no public key material');

  my ($foreign) = grep { $_->{name} eq "other-key-${pid}" } @{$j->{data}};
  ok(!$foreign, 'foreign server keys not listed');
};

subtest 'GET keys - algo filter (TSIG family / exact, issue #55)' => sub {
  $t->get_ok("$KEYS?algo=-1" => $SUPER)->status_is(200);
  my %t = map { $_->{id} => 1 } @{$t->tx->res->json->{data}};
  ok($t{$key_id} && $t{$sha1_key_id}, 'algo=-1 lists both HMAC keys');
  ok(!$t{$rsa_key_id},              'algo=-1 excludes the non-HMAC key');

  $t->get_ok("$KEYS?algo=158" => $SUPER)->status_is(200);
  my @exact = @{$t->tx->res->json->{data}};
  is(scalar @exact,    1,            'algo=158 returns exactly one');
  is($exact[0]{id},    $sha1_key_id, 'exact algorithm match');

  $t->get_ok("$KEYS?algo=abc" => $SUPER)->status_is(400);
};

subtest 'GET keys - filters and authz' => sub {
  $t->get_ok("$KEYS?name=xfer" => $SUPER)->status_is(200);
  my $j = $t->tx->res->json;
  ok((grep { $_->{id} == $key_id } @{$j->{data}}), 'name filter matches');

  $t->get_ok("$KEYS?bogus=1" => $SUPER)->status_is(400);

  $t->get_ok($KEYS => $LOW)->status_is(403);
  $t->get_ok($KEYS => $LEVEL5)->status_is(200);
};

done_testing();
