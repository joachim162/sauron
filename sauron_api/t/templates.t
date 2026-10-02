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
  grant_server_access
);

my $t = setup_test_app();

my $pid = $$;
(my $letters = $pid) =~ tr/0-9/a-j/;
my (@users, @servers, @zones, @printer_classes, @hinfo);

sub _cleanup_templates {
  for my $name (@printer_classes) {
    Sauron::DB::db_exec(
      "DELETE FROM printer_entries WHERE ref IN (SELECT id FROM printer_classes WHERE name='$name')");
    Sauron::DB::db_exec("DELETE FROM printer_classes WHERE name='$name'");
  }
  for my $v (@hinfo) {
    Sauron::DB::db_exec("DELETE FROM hinfo_templates WHERE hinfo='$v'");
  }
}

END {
  _cleanup_templates();
  for my $z (@zones)   { eval { delete_test_zone($z); }; }
  for my $s (@servers) { eval { delete_test_server($s); }; }
  for my $u (@users)   { eval { delete_test_user($u); }; }
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

my $srv  = create_test_server(name => "srv-tmpl-${pid}", comment => 'Templates test');
my $srv2 = create_test_server(name => "srv-tmpl2-${pid}", comment => 'Templates test, second server');
push @servers, $srv, $srv2;
my $srv_name  = "srv-tmpl-${pid}";
my $srv2_name = "srv-tmpl2-${pid}";

my $zone = create_test_zone(server_id => $srv, name => "zone-${pid}.example.com");
my $zone2 = create_test_zone(server_id => $srv, name => "zone2-${pid}.example.com");
push @zones, $zone, $zone2;
my $zone_name  = "zone-${pid}.example.com";
my $zone2_name = "zone2-${pid}.example.com";

my $super  = create_test_user(username => "tmplsuper_${pid}", email => "tmplsuper_${pid}\@example.com", superuser => 1);
my $reader = create_test_user(username => "tmplread_${pid}",  email => "tmplread_${pid}\@example.com");
my $mxuser = create_test_user(username => "tmplmx_${pid}",    email => "tmplmx_${pid}\@example.com");
my $plain  = create_test_user(username => "tmplplain_${pid}", email => "tmplplain_${pid}\@example.com");
my $alvl   = create_test_user(username => "tmplalvl_${pid}",  email => "tmplalvl_${pid}\@example.com");
push @users, $super, $reader, $mxuser, $plain, $alvl;

grant_server_access($reader, $srv, 'R');
grant_server_access($mxuser, $srv, 'R');
grant_server_access($alvl,   $srv, 'R');

# mxuser may manage any MX template name (tmplmask rtype 9)
Sauron::BackEnd::add_record('user_rights', {
  type => 2, ref => $mxuser, rtype => 9, rref => 0, rule => '.*',
});
# alvl user: authorization level 10
Sauron::BackEnd::add_record('user_rights', {
  type => 2, ref => $alvl, rtype => 6, rref => 0, rule => 10,
});

sub _hdr {
  my ($name) = @_;
  $t->reset_session;
  return { 'X-Remote-User' => $name };
}
my $SUPER  = _hdr("tmplsuper_${pid}\@example.com");
my $READER = _hdr("tmplread_${pid}\@example.com");
my $MXUSER = _hdr("tmplmx_${pid}\@example.com");
my $PLAIN  = _hdr("tmplplain_${pid}\@example.com");
my $ALVL   = _hdr("tmplalvl_${pid}\@example.com");

my $MXB  = "/api/v1/servers/$srv_name/zones/$zone_name/mx-templates";
my $MXBA = "/api/v1/servers/$srv_name/zones/$zone_name/assignable-mx-templates";
my $WKSB = "/api/v1/servers/$srv_name/wks-templates";
my $WKSBA = "/api/v1/servers/$srv_name/assignable-wks-templates";
my $PCB  = "/api/v1/printer-classes";
my $HB   = "/api/v1/hinfo-templates";

# ========================================================================
# MX templates (zone-scoped; write gate = server R + tmplmask)
# ========================================================================

my $mxA;
subtest 'MX: create with entries (superuser)' => sub {
  $t->post_ok($MXB => $SUPER => json => {
    name => 'mail-forwarder', comment => 'fwd', alevel => 0,
    mx_l => [{ pri => 10, mx => 'mail1.example.com', comment => 'm1' }],
  })->status_is(201)->json_has('/id')->json_is('/zone_id' => $zone);
  my $j = $t->tx->res->json;
  $mxA = $j->{id};
  is($j->{name}, 'mail-forwarder', 'name');
  is_deeply($j->{mx_l}, [{ pri => 10, mx => 'mail1.example.com', comment => 'm1' }],
    'mx_l round-trips with comment');
  is($j->{host_count}, 0, 'host_count');
};

subtest 'MX: create requires server R and tmplmask' => sub {
  $t->post_ok($MXB => $PLAIN => json => { name => 'x' })->status_is(403);
  $t->post_ok($MXB => $READER => json => { name => 'x' })->status_is(403)
    ->json_is('/message' => 'Not authorized to modify this template');
};

subtest 'MX: tmplmask user may create' => sub {
  $t->post_ok($MXB => $MXUSER => json => { name => 'mx-masked' })
    ->status_is(201);
  my $id = $t->tx->res->json->{id};
  $t->delete_ok("$MXB/$id" => $SUPER)->status_is(204);
};

subtest 'MX: validation' => sub {
  $t->post_ok($MXB => $SUPER => json => {})->status_is(400);
  $t->post_ok($MXB => $SUPER => json => { name => 'neg', alevel => -1 })->status_is(400);
  $t->post_ok($MXB => $SUPER => json => {
    name => 'badentry', mx_l => [{ mx => 'no-pri.example.com' }],
  })->status_is(400);
};

subtest 'MX: list envelope, summary omits entries, filters/sort' => sub {
  $t->get_ok($MXB => $READER)->status_is(200);
  my $j = $t->tx->res->json;
  ok(ref $j->{data} eq 'ARRAY' && exists $j->{metadata}, 'paginated envelope');
  my ($found) = grep { $_->{name} eq 'mail-forwarder' } @{$j->{data}};
  ok($found, 'created template listed');
  ok(!exists $found->{mx_l}, 'summary omits mx_l');
  ok(!exists $found->{host_count}, 'summary omits host_count');
  is($found->{zone_id}, $zone, 'summary zone_id');

  $t->get_ok("$MXB?name=mail-forwarder\$" => $READER)->status_is(200);
  ok((grep { $_->{name} eq 'mail-forwarder' } @{$t->tx->res->json->{data}}), 'name filter');
  $t->get_ok("$MXB?alevel=0" => $READER)->status_is(200);
  $t->get_ok("$MXB?sort=name:desc" => $READER)->status_is(200);
  $t->get_ok("$MXB?bogus=1" => $READER)->status_is(400);
  $t->get_ok("$MXB?per_page=101" => $READER)->status_is(400);
};

subtest 'MX: detail and 404' => sub {
  $t->get_ok("$MXB/$mxA" => $READER)->status_is(200);
  my $j = $t->tx->res->json;
  ok(exists $j->{mx_l} && exists $j->{host_count}, 'detail has mx_l + host_count');
  $t->get_ok("$MXB/999999999" => $READER)->status_is(404);
};

subtest 'MX: update partial preserves entries; replace-all works' => sub {
  $t->put_ok("$MXB/$mxA" => $SUPER => json => { comment => 'updated' })
    ->status_is(200)->json_is('/comment' => 'updated');
  is(scalar @{$t->tx->res->json->{mx_l}}, 1, 'mx_l preserved on partial update');

  $t->put_ok("$MXB/$mxA" => $SUPER => json => {
    mx_l => [{ pri => 20, mx => 'mail2.example.com' }],
  })->status_is(200);
  is_deeply($t->tx->res->json->{mx_l},
    [{ pri => 20, mx => 'mail2.example.com', comment => undef }], 'mx_l replaced');
};

subtest 'MX: delete with reassign moves referencing hosts' => sub {
  Sauron::BackEnd::set_muser('test');
  my $mxB = $t->post_ok($MXB => $SUPER => json => { name => 'mail-direct' })
    ->status_is(201)->tx->res->json->{id};

  Sauron::DB::db_exec(
    "INSERT INTO hosts (zone,type,domain,mx) VALUES ($zone,1,'mxhost-${pid}',$mxA)");
  my @q;
  Sauron::DB::db_query("SELECT id FROM hosts WHERE zone=$zone AND domain='mxhost-${pid}'", \@q);
  my $host_id = $q[0][0];
  ok($host_id > 0, 'referencing host created');

  $t->get_ok("$MXB/$mxA" => $READER)->status_is(200)->json_is('/host_count' => 1);

  $t->delete_ok("$MXB/$mxA?reassign_to=$mxB" => $SUPER)->status_is(204);
  $t->get_ok("$MXB/$mxA" => $READER)->status_is(404);
  Sauron::DB::db_query("SELECT mx FROM hosts WHERE id=$host_id", \@q);
  is($q[0][0], $mxB, 'host reassigned to new template');

  # Default delete detaches.
  $t->delete_ok("$MXB/$mxB" => $SUPER)->status_is(204);
  Sauron::DB::db_query("SELECT mx FROM hosts WHERE id=$host_id", \@q);
  is($q[0][0], -1, 'host detached by default delete');
  Sauron::DB::db_exec("DELETE FROM hosts WHERE id=$host_id");

  $t->get_ok("$MXB/$mxB" => $SUPER)->status_is(404);
};

subtest 'MX: delete reassign validation' => sub {
  my $id = $t->post_ok($MXB => $SUPER => json => { name => 'reassign-check' })
    ->status_is(201)->tx->res->json->{id};
  $t->delete_ok("$MXB/$id?reassign_to=$id" => $SUPER)->status_is(400);
  $t->delete_ok("$MXB/$id?reassign_to=999999999" => $SUPER)->status_is(404);
  $t->delete_ok("$MXB/$id?reassign_to=abc" => $SUPER)->status_is(400);
  $t->delete_ok("$MXB/$id" => $SUPER)->status_is(204);
};

subtest 'MX: singleton is zone-scoped (no cross-zone access or mutation)' => sub {
  my $MXB2 = "/api/v1/servers/$srv_name/zones/$zone2_name/mx-templates";
  my $id = $t->post_ok($MXB => $SUPER => json => { name => 'zone-scoped' })
    ->status_is(201)->tx->res->json->{id};
  $t->get_ok("$MXB2/$id" => $SUPER)->status_is(404);
  $t->put_ok("$MXB2/$id" => $SUPER => json => { comment => 'x' })->status_is(404);
  $t->delete_ok("$MXB2/$id" => $SUPER)->status_is(404);
  $t->get_ok("$MXB/$id" => $SUPER)->status_is(200);
  $t->delete_ok("$MXB/$id" => $SUPER)->status_is(204);
};

subtest 'MX: assignable picker applies alevel ceiling' => sub {
  my $hi = $t->post_ok($MXB => $SUPER => json => { name => 'hi-level', alevel => 5 })
    ->status_is(201)->tx->res->json->{id};
  my $lo = $t->post_ok($MXB => $SUPER => json => { name => 'lo-level', alevel => 0 })
    ->status_is(201)->tx->res->json->{id};

  $t->get_ok($MXBA => $READER)->status_is(200);
  my $names = [ map { $_->{name} } @{$t->tx->res->json} ];
  ok(!(grep { $_ eq 'hi-level' } @$names), 'alevel 5 hidden from alevel 0 caller');
  ok((grep { $_ eq 'lo-level' } @$names), 'alevel 0 visible');

  $t->get_ok($MXBA => $ALVL)->status_is(200);
  $names = [ map { $_->{name} } @{$t->tx->res->json} ];
  ok((grep { $_ eq 'hi-level' } @$names), 'alevel 5 visible to alevel 10 caller');

  $t->get_ok($MXBA => $SUPER)->status_is(200);
  $names = [ map { $_->{name} } @{$t->tx->res->json} ];
  ok((grep { $_ eq 'hi-level' } @$names), 'superuser sees all');

  $t->delete_ok("$MXB/$hi" => $SUPER)->status_is(204);
  $t->delete_ok("$MXB/$lo" => $SUPER)->status_is(204);
};

# ========================================================================
# WKS templates (server-scoped; write gate = superuser)
# ========================================================================

my $wksA;
subtest 'WKS: create requires superuser' => sub {
  $t->post_ok($WKSB => $SUPER => json => {
    name => 'standard', alevel => 0,
    wks_l => [{ proto => 'tcp', services => 'smtp,http', comment => 'w1' }],
  })->status_is(201);
  my $j = $t->tx->res->json;
  $wksA = $j->{id};
  is($j->{server_id}, $srv, 'server_id');
  is_deeply($j->{wks_l}, [{ proto => 'tcp', services => 'smtp,http', comment => 'w1' }],
    'wks_l round-trips');

  $t->post_ok($WKSB => $READER => json => { name => 'nope' })->status_is(403);
};

subtest 'WKS: services may be empty (legacy quirk)' => sub {
  my $id = $t->post_ok($WKSB => $SUPER => json => {
    name => 'empty-services', wks_l => [{ proto => 'udp' }],
  })->status_is(201)->tx->res->json->{id};
  is_deeply($t->tx->res->json->{wks_l}, [{ proto => 'udp', services => undef, comment => undef }],
    'empty services accepted');
  $t->delete_ok("$WKSB/$id" => $SUPER)->status_is(204);
};

subtest 'WKS: list/detail/update/delete' => sub {
  $t->get_ok($WKSB => $READER)->status_is(200);
  my $j = $t->tx->res->json;
  my ($entry) = grep { $_->{id} == $wksA } @{$j->{data}};
  ok($j->{metadata} && $entry && !exists $entry->{wks_l}, 'summary omits wks_l');

  $t->get_ok("$WKSB/$wksA" => $READER)->status_is(200)->json_has('/wks_l');
  $t->put_ok("$WKSB/$wksA" => $SUPER => json => { comment => 'w-updated' })
    ->status_is(200)->json_is('/comment' => 'w-updated');
  $t->get_ok($WKSBA => $READER)->status_is(200);
  $t->delete_ok("$WKSB/$wksA" => $SUPER)->status_is(204);
  $t->get_ok("$WKSB/$wksA" => $READER)->status_is(404);
};

subtest 'WKS: singleton is server-scoped (no cross-server access or mutation)' => sub {
  my $WKSB2 = "/api/v1/servers/$srv2_name/wks-templates";
  my $id = $t->post_ok($WKSB => $SUPER => json => { name => 'server-scoped' })
    ->status_is(201)->tx->res->json->{id};
  $t->get_ok("$WKSB2/$id" => $SUPER)->status_is(404);
  $t->put_ok("$WKSB2/$id" => $SUPER => json => { comment => 'cross-server' })
    ->status_is(404);
  $t->get_ok("$WKSB/$id" => $SUPER)->status_is(200)->json_is('/comment' => undef);
  $t->delete_ok("$WKSB2/$id" => $SUPER)->status_is(404);
  $t->get_ok("$WKSB/$id" => $SUPER)->status_is(200);
  $t->delete_ok("$WKSB/$id" => $SUPER)->status_is(204);
};

subtest 'WKS: write on nonexistent id returns 404' => sub {
  $t->put_ok("$WKSB/999999999" => $SUPER => json => { name => 'x' })
    ->status_is(404);
  $t->delete_ok("$WKSB/999999999" => $SUPER)->status_is(404);
};

# ========================================================================
# PRINTER classes (global; read = any authenticated; write = superuser)
# ========================================================================

my $pcA;
subtest 'PRINTER: create (regex) and validation' => sub {
  my $name = "\@lw${letters}";
  push @printer_classes, $name;
  $t->post_ok($PCB => $SUPER => json => {
    name => $name, comment => 'laser',
    printer_l => [{ printer => ':lp=@lw', comment => 'p1' }],
  })->status_is(201);
  my $j = $t->tx->res->json;
  $pcA = $j->{id};
  is($j->{name}, $name, 'name @letters');
  is_deeply($j->{printer_l}, [{ printer => ':lp=@lw', comment => 'p1' }], 'printer_l round-trips');

  $t->post_ok($PCB => $SUPER => json => { name => 'no-at-sign' })->status_is(400);
  $t->post_ok($PCB => $SUPER => json => { name => "\@has123" })->status_is(400);
  $t->post_ok($PCB => $READER => json => { name => "\@reader${letters}" })->status_is(403);
};

subtest 'PRINTER: global read for any authenticated user' => sub {
  $t->get_ok($PCB => $PLAIN)->status_is(200);
  my $j = $t->tx->res->json;
  ok($j->{metadata}, 'envelope');
  $t->get_ok("$PCB/$pcA" => $PLAIN)->status_is(200)->json_has('/printer_l');
  $t->get_ok("$PCB?name=laser" => $PLAIN)->status_is(200);
};

subtest 'PRINTER: update/delete' => sub {
  $t->put_ok("$PCB/$pcA" => $SUPER => json => { comment => 'changed' })
    ->status_is(200)->json_is('/comment' => 'changed');
  $t->delete_ok("$PCB/$pcA" => $READER)->status_is(403);
  $t->delete_ok("$PCB/$pcA" => $SUPER)->status_is(204);
  $t->get_ok("$PCB/$pcA" => $SUPER)->status_is(404);
};

subtest 'PRINTER: write on nonexistent id returns 404' => sub {
  $t->put_ok("$PCB/999999999" => $SUPER => json => { name => '\@x' })
    ->status_is(404);
  $t->delete_ok("$PCB/999999999" => $SUPER)->status_is(404);
};

subtest 'PRINTER: duplicate name returns 409 (name is UNIQUE)' => sub {
  my ($first, $second) = ("\@dup${letters}", "\@other${letters}");
  push @printer_classes, $first, $second;
  my $id1 = $t->post_ok($PCB => $SUPER => json => { name => $first })
    ->status_is(201)->tx->res->json->{id};
  my $id2 = $t->post_ok($PCB => $SUPER => json => { name => $second })
    ->status_is(201)->tx->res->json->{id};
  $t->post_ok($PCB => $SUPER => json => { name => $first })->status_is(409);
  $t->put_ok("$PCB/$id2" => $SUPER => json => { name => $first })
    ->status_is(409);
  $t->put_ok("$PCB/$id1" => $SUPER => json => { name => $first })
    ->status_is(200);
  $t->delete_ok("$PCB/$id1" => $SUPER)->status_is(204);
  $t->delete_ok("$PCB/$id2" => $SUPER)->status_is(204);
};

# ========================================================================
# HINFO templates (global; read = any authenticated; write = superuser)
# ========================================================================

subtest 'HINFO: create with defaults' => sub {
  push @hinfo, 'PC-PORTABLE';
  push @hinfo, 'SUN-WS';
  push @hinfo, 'ULTRA-SPARC';
  $t->post_ok($HB => $SUPER => json => { hinfo => 'PC-PORTABLE' })->status_is(201);
  my $j = $t->tx->res->json;
  is($j->{type}, 'hardware', 'type defaults to hardware');
  is($j->{pri},  100, 'pri defaults to 100');
  $t->post_ok($HB => $SUPER => json => { hinfo => 'SUN-WS', type => 'software', pri => 5 })
    ->status_is(201)->json_is('/type' => 'software');
};

subtest 'HINFO: value charset validation' => sub {
  $t->post_ok($HB => $SUPER => json => { hinfo => 'lower-case' })->status_is(400);
  $t->post_ok($HB => $SUPER => json => { hinfo => 'has space' })->status_is(400);
  $t->post_ok($HB => $SUPER => json => { hinfo => 'A/B' })->status_is(201); # '/' allowed
  push @hinfo, 'A/B';
};

subtest 'HINFO: global read + filters' => sub {
  $t->get_ok($HB => $PLAIN)->status_is(200);
  my $j = $t->tx->res->json;
  ok($j->{metadata}, 'envelope');
  $t->get_ok("$HB?type=software" => $PLAIN)->status_is(200);
  ok((grep { $_->{type} eq 'software' } @{$t->tx->res->json->{data}}), 'type filter');
  $t->get_ok("$HB?hinfo=SUN" => $PLAIN)->status_is(200);
  ok((grep { $_->{hinfo} =~ /SUN/ } @{$t->tx->res->json->{data}}), 'hinfo filter');
  $t->get_ok("$HB?sort=pri:asc" => $PLAIN)->status_is(200);
  $t->get_ok("$HB?type=bogus" => $PLAIN)->status_is(400);
};

subtest 'HINFO: update requires superuser; delete' => sub {
  $t->get_ok("$HB?hinfo=SUN-WS" => $SUPER)->status_is(200);
  my $id = $t->tx->res->json->{data}[0]{id};
  $t->put_ok("$HB/$id" => $PLAIN => json => { pri => 1 })->status_is(403);
  $t->put_ok("$HB/$id" => $SUPER => json => { pri => 1 })->status_is(200)->json_is('/pri' => 1);
  $t->delete_ok("$HB/$id" => $SUPER)->status_is(204);
};

subtest 'HINFO: write on nonexistent id returns 404' => sub {
  $t->put_ok("$HB/999999999" => $SUPER => json => { pri => 1 })
    ->status_is(404);
  $t->delete_ok("$HB/999999999" => $SUPER)->status_is(404);
};

subtest 'HINFO: duplicate value returns 409 (hinfo is UNIQUE)' => sub {
  push @hinfo, "DUP-${pid}", "OTHER-${pid}";
  my $id1 = $t->post_ok($HB => $SUPER => json => { hinfo => "DUP-${pid}" })
    ->status_is(201)->tx->res->json->{id};
  my $id2 = $t->post_ok($HB => $SUPER => json => { hinfo => "OTHER-${pid}" })
    ->status_is(201)->tx->res->json->{id};
  $t->post_ok($HB => $SUPER => json => { hinfo => "DUP-${pid}" })->status_is(409);
  $t->put_ok("$HB/$id2" => $SUPER => json => { hinfo => "DUP-${pid}" })
    ->status_is(409);
  $t->put_ok("$HB/$id1" => $SUPER => json => { hinfo => "DUP-${pid}" })
    ->status_is(200);
  $t->delete_ok("$HB/$id1" => $SUPER)->status_is(204);
  $t->delete_ok("$HB/$id2" => $SUPER)->status_is(204);
};

done_testing;
