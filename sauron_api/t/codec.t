use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../..";

use SauronAPI::Codecs qw(aml mx value forwarder);
use SauronAPI::FieldCodec;

# ========================================================================
# AML codec
# ========================================================================

subtest 'aml - decode' => sub {
  my $c = aml();
  my $backend = [
    ['aml', 0],
    [1, 0, '10.0.0.1', '',   0, 0, '', 2],
    [2, 1, '0.0.0.0',  '1', 0, 0, 'acl:trusted', 2],
  ];
  my $got = $c->decode($backend);
  is(ref $got, 'ARRAY', 'returns arrayref');
  is(scalar @$got, 2, 'two rows');
  is($got->[0]{mode}, 0, 'mode');
  is($got->[0]{ip}, '10.0.0.1', 'ip');
  is($got->[0]{acl}, '', 'acl');
  is($got->[1]{acl}, 1, 'acl by id');
  is($got->[1]{comment}, 'acl:trusted', 'comment');
};

subtest 'aml - encode_create keeps header' => sub {
  my $c = aml();
  my $api = [
    { mode => 0, ip => '10.0.0.1', acl => 0, tkey => 0, op => 0, comment => '' },
  ];
  my $got = $c->encode_create($api);
  is(ref $got, 'ARRAY', 'returns arrayref');
  is($got->[0][0], 'aml', 'header preserved');
  is($got->[0][1], 0, 'aml sub-type 0');
  is($got->[1][0], 0, 'new row id=0');
  is($got->[1][1], 0, 'mode');
  is($got->[1][2], '10.0.0.1', 'ip');
  is($got->[1][7], 2, 'trailing marker');
};

subtest 'aml - encode_update' => sub {
  my $c = aml();
  my $api = [
    { mode => 0, ip => '10.0.0.2', acl => 0, tkey => 0, op => 0, comment => '' },
  ];
  my $existing = [
    ['aml', 0],
    [1, 0, '10.0.0.1', '', 0, 0, '', 2],
  ];
  my $got = $c->encode_update($api, $existing);
  is(ref $got, 'ARRAY', 'returns arrayref');
  is($got->[0][0], 'aml', 'header');
  is($got->[1][0], 1, 'existing id 1 marked');
  is($got->[1][7], -1, 'deletion marker');
  is($got->[2][0], 0, 'new row id=0');
  is($got->[2][2], '10.0.0.2', 'new ip');
};

# ========================================================================
# MX codec
# ========================================================================

subtest 'mx - decode' => sub {
  my $c = mx();
  my $backend = [
    ['Priority', 'MX', 'Comments'],
    [1, 10, 'mail.example.com', 'primary', 2],
  ];
  my $got = $c->decode($backend);
  is(scalar @$got, 1, 'one row');
  is($got->[0]{pri}, 10, 'priority');
  is($got->[0]{mx}, 'mail.example.com', 'mx');
  is($got->[0]{comment}, 'primary', 'comment');
};

subtest 'mx - encode_create strips header' => sub {
  my $c = mx();
  my $api = [
    { pri => 20, mx => 'backup.example.com', comment => 'backup' },
  ];
  my $got = $c->encode_create($api);
  is(ref $got, 'ARRAY', 'returns arrayref');
  is(scalar @$got, 1, 'one row (header stripped)');
  is($got->[0][0], 0, 'new row id=0');
  is($got->[0][1], 20, 'priority');
  is($got->[0][2], 'backup.example.com', 'mx');
  is($got->[0][3], 'backup', 'comment');
  is($got->[0][4], 2, 'trailing marker');
};

subtest 'mx - round-trip' => sub {
  my $c = mx();
  my $api = [{ pri => 10, mx => 'mx.example.com', comment => 'test' }];
  my $encoded = $c->encode_update($api, []);
  my $decoded = $c->decode($encoded);
  is(scalar @$decoded, 1, 'one row');
  is($decoded->[0]{pri}, 10, 'priority round-trip');
  is($decoded->[0]{mx}, 'mx.example.com', 'mx round-trip');
  is($decoded->[0]{comment}, 'test', 'comment round-trip');
};

# ========================================================================
# Value codec
# ========================================================================

subtest 'value - decode with comment' => sub {
  my $c = value(key => 'dhcp', label => 'DHCP');
  my $backend = [
    ['DHCP', 'Comments'],
    [1, 'option routers 10.0.0.1', 'default gateway', 2],
  ];
  my $got = $c->decode($backend);
  is(scalar @$got, 1, 'one row');
  is($got->[0]{dhcp}, 'option routers 10.0.0.1', 'dhcp value');
  is($got->[0]{comment}, 'default gateway', 'comment');
};

subtest 'value - decode without comment' => sub {
  my $c = value(key => 'txt', label => 'TXT', comment => 0);
  my $backend = [
    ['TXT'],
    [1, 'v=spf1 mx -all', 2],
  ];
  my $got = $c->decode($backend);
  is(scalar @$got, 1, 'one row');
  is($got->[0]{txt}, 'v=spf1 mx -all', 'txt value');
  ok(!exists $got->[0]{comment}, 'no comment key');
};

subtest 'value - encode_create strips header' => sub {
  my $c = value(key => 'ns', label => 'NS');
  my $api = [{ ns => 'ns1.example.com', comment => 'primary' }];
  my $got = $c->encode_create($api);
  is(ref $got, 'ARRAY', 'returns arrayref');
  is(scalar @$got, 1, 'one row');
  is($got->[0][1], 'ns1.example.com', 'ns value');
  is($got->[0][2], 'primary', 'comment');
  is($got->[0][3], 2, 'trailing marker');
};

# ========================================================================
# Forwarder codec
# ========================================================================

subtest 'forwarder - with_port' => sub {
  my $c = forwarder(with_port => 1);
  my $api = [
    { ip => '192.168.1.1', port => '53', comment => 'internal' },
  ];
  my $got = $c->encode_create($api);
  is(ref $got, 'ARRAY', 'returns arrayref');
  is($got->[0][0], 0, 'id=0');
  is($got->[0][1], '192.168.1.1', 'ip');
  is($got->[0][2], '53', 'port');
  is($got->[0][3], 'internal', 'comment');
  is($got->[0][4], 2, 'marker');
};

subtest 'forwarder - without_port' => sub {
  my $c = forwarder(with_port => 0);
  my $api = [
    { ip => '8.8.8.8', comment => 'Google DNS' },
  ];
  my $got = $c->encode_create($api);
  is($got->[0][1], '8.8.8.8', 'ip');
  is($got->[0][2], 'Google DNS', 'comment');
  is($got->[0][3], 2, 'marker');
};

subtest 'forwarder - decode with_port' => sub {
  my $c = forwarder(with_port => 1);
  my $backend = [
    ['IP', 'Port', 'Comments'],
    [1, '192.168.1.1', '53', 'internal', 2],
  ];
  my $got = $c->decode($backend);
  is(scalar @$got, 1, 'one row');
  is($got->[0]{ip}, '192.168.1.1', 'ip');
  is($got->[0]{port}, '53', 'port');
  is($got->[0]{comment}, 'internal', 'comment');
};

# ========================================================================
# ip codec (Host.pm special case)
# ========================================================================

subtest 'ip - encode_create takes flat strings' => sub {
  my $c = SauronAPI::FieldCodec->new(
    backend_header => ['IP', 'reverse', 'forward'],
    api_columns    => [qw(ip reverse forward)],
    build_row      => sub { [0, $_[0], 't', 't', 2] },
    marker_count   => 4,
  );
  my $got = $c->encode_create(['10.0.0.1', '10.0.0.2']);
  is(ref $got, 'ARRAY', 'returns arrayref');
  is(scalar @$got, 2, 'two rows');
  is($got->[0][0], 0, 'first id=0');
  is($got->[0][1], '10.0.0.1', 'first ip');
  is($got->[0][2], 't', 'reverse');
  is($got->[0][3], 't', 'forward');
  is($got->[0][4], 2, 'marker');
  is($got->[1][1], '10.0.0.2', 'second ip');
};

subtest 'ip - encode_update with existing' => sub {
  my $c = SauronAPI::FieldCodec->new(
    backend_header => ['IP', 'reverse', 'forward'],
    api_columns    => [qw(ip reverse forward)],
    build_row      => sub { [0, $_[0], 't', 't', 2] },
    marker_count   => 4,
  );
  my $existing = [
    ['IP', 'reverse', 'forward'],
    [1, '10.0.0.1', 't', 't', 2],
  ];
  my $got = $c->encode_update(['10.0.0.3'], $existing);
  is(ref $got, 'ARRAY', 'returns arrayref');
  is($got->[0][0], 'IP', 'header');
  is($got->[1][0], 1, 'existing id');
  is($got->[1][4], -1, 'deletion marker');
  is($got->[2][0], 0, 'new id');
  is($got->[2][1], '10.0.0.3', 'new ip');
};

# ========================================================================
# encode_update with empty existing data
# ========================================================================

subtest 'encode_update with no existing rows' => sub {
  my $c = mx();
  my $api = [{ pri => 10, mx => 'mx.example.com', comment => '' }];
  my $got = $c->encode_update($api, []);
  is(scalar @$got, 2, 'header + 1 data row');
  is($got->[1][1], 10, 'priority');
};

# ========================================================================
# decode on empty/undef returns []
# ========================================================================

subtest 'decode on empty data' => sub {
  my $c = mx();
  is_deeply($c->decode([]), [], 'empty array');
  is_deeply($c->decode(undef), [], 'undef');
  is_deeply($c->decode(['header']), [], 'single row (no data)');
};

subtest 'encode_create on non-array returns undef' => sub {
  my $c = mx();
  is($c->encode_create(undef), undef, 'undef');
  is($c->encode_create('string'), undef, 'string');
  is($c->encode_create({}), undef, 'hash');
};

done_testing();
