use strict;
use warnings;

use Test::More;
use Test::MockModule;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../..";

use Sauron::DB               ();
use Sauron::BackEnd          ();
use SauronAPI::Exception     ();
use SauronAPI::Exception::NotFound;
use SauronAPI::Exception::Conflict;
use SauronAPI::Exception::Validation;
use SauronAPI::Exception::Permission;
use SauronAPI::Repository::Host qw(
  host_list host_find host_create host_update host_delete
);

# Keep mock objects alive at file scope so DESTROY doesn't unmock them mid-test.
our @MOCKS;

sub _mock_back_end {
  my (%behaviour) = @_;
  my $mod = Test::MockModule->new('Sauron::BackEnd');
  for my $k (keys %behaviour) {
    $mod->mock($k, $behaviour{$k});
  }
  push @MOCKS, $mod;
  return $mod;
}

sub _mock_db {
  my (%queries) = @_;
  my $mod = Test::MockModule->new('Sauron::DB');
  $mod->mock('db_query', sub {
    my ($sql, $out) = @_;
    for my $pattern (keys %queries) {
      if (index($sql, $pattern) >= 0) {
        my $rows = $queries{$pattern};
        @$out = @$rows;
        return scalar @$rows;
      }
    }
    @$out = ();
    return 0;
  });
  $mod->mock('db_encode_str', sub { my $v = shift; $v =~ s/'/''/g; "'$v'" });
  push @MOCKS, $mod;
  return $mod;
}

sub _reset_mocks {
  for my $m (@MOCKS) {
    eval { $m->unmock_all };
  }
  @MOCKS = ();
}

subtest 'Exception::NotFound throws and stringify works' => sub {
  eval { SauronAPI::Exception::NotFound->throw(message => 'gone') };
  ok $@, 'exception was thrown';
  isa_ok $@, 'SauronAPI::Exception::NotFound';
  is $@->http_status, 404, 'http_status is 404';
  is $@->kind, 'Not Found', 'kind is "Not Found"';
  is "$@", 'gone', 'stringifies to message';
};

subtest 'eval { } catches thrown exception and ref is preserved' => sub {
  eval { SauronAPI::Exception::Conflict->throw(message => 'dup') };
  isa_ok $@, 'SauronAPI::Exception::Conflict';
  is $@->http_status, 409, 'http_status 409';
  is $@->kind, 'Conflict', 'kind is Conflict';
};

subtest 'host_list returns paginated envelope' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { 7 },
    get_zone_id_by_name => sub { 42 },
  );
  _mock_db(
    'SELECT id,domain,type FROM hosts' => [
      [100, 'a.example', 1],
      [101, 'b.example', 1],
      [102, 'c.example', 1],
    ],
    'SELECT COUNT(*)' => [[3]],
  );

  my ($data, $meta) = host_list('example', 'example.com');
  is ref $data, 'ARRAY', 'data is arrayref';
  is scalar @$data, 3, 'three rows';
  is $data->[0]{domain}, 'a.example', 'first row domain';
  is $data->[0]{zone_id}, 42, 'zone_id propagated';
  is $meta->{pagination}{total}, 3, 'total in metadata';
  is $meta->{pagination}{page}, 1, 'default page 1';
  is $meta->{pagination}{per_page}, 50, 'default per_page 50';
  is $meta->{pagination}{total_pages}, 1, 'total_pages';
  is_deeply $meta->{sort}, [], 'empty sort';
  is_deeply $meta->{filters}, [], 'empty filters';
};

subtest 'host_list honours page and per_page' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { 7 },
    get_zone_id_by_name => sub { 42 },
  );
  _mock_db(
    'SELECT id,domain,type FROM hosts' => [
      [100, 'a'], [101, 'b'], [102, 'c'],
      [103, 'd'], [104, 'e'], [105, 'f'],
    ],
    'SELECT COUNT(*)' => [[6]],
  );

  my ($data, $meta) = host_list('example', 'example.com', page => 2, per_page => 2);
  is scalar @$data, 2, 'page 2 of 6 items, per_page 2 -> 2 rows';
  is $meta->{pagination}{page}, 2, 'page in metadata';
  is $meta->{pagination}{per_page}, 2, 'per_page in metadata';
  is $meta->{pagination}{total_pages}, 3, 'total_pages is 3';
  is $data->[0]{domain}, 'c', 'first item on page 2';
};

subtest 'host_list throws NotFound when server missing' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { -1 },
    get_zone_id_by_name => sub { 42 },
  );
  eval { host_list('missing', 'example.com') };
  isa_ok $@, 'SauronAPI::Exception::NotFound';
  like $@->message, qr/Server 'missing' not found/, 'message mentions server';
};

subtest 'host_list throws NotFound when zone missing' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { 7 },
    get_zone_id_by_name => sub { -1 },
  );
  eval { host_list('example', 'missing') };
  isa_ok $@, 'SauronAPI::Exception::NotFound';
  like $@->message, qr/Zone 'missing' not found/, 'message mentions zone';
};

subtest 'host_find throws NotFound when host missing' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { 7 },
    get_zone_id_by_name => sub { 42 },
    get_host_id         => sub { -1 },
  );
  eval { host_find('example', 'example.com', 'absent') };
  isa_ok $@, 'SauronAPI::Exception::NotFound';
  like $@->message, qr/Host 'absent' not found/, 'message mentions host';
};

subtest 'host_create throws Validation when hostname missing' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { 7 },
    get_zone_id_by_name => sub { 42 },
  );
  eval { host_create('example', 'example.com', { type => 1 }) };
  isa_ok $@, 'SauronAPI::Exception::Validation';
  like $@->message, qr/hostname/, 'mentions hostname';
};

subtest 'host_create throws Conflict when hostname already exists' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { 7 },
    get_zone_id_by_name => sub { 42 },
    get_host_id         => sub { 99 },
  );
  eval {
    host_create('example', 'example.com', { hostname => 'dup', type => 1 });
  };
  isa_ok $@, 'SauronAPI::Exception::Conflict';
  like $@->message, qr/already exists/, 'mentions existing host';
};

subtest 'host_create throws Validation on type-invalid field' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { 7 },
    get_zone_id_by_name => sub { 42 },
    get_host_id         => sub { -1 },
  );
  eval {
    host_create('example', 'example.com', {
      hostname => 'newone', type => 4, srv_l => [{ pri => 1, weight => 1, port => 80, target => 'x', comment => '' }],
    });
  };
  isa_ok $@, 'SauronAPI::Exception::Validation';
  like $@->message, qr/srv_l/, 'mentions invalid field srv_l for type 4';
};

subtest 'host_delete throws NotFound when host missing' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { 7 },
    get_zone_id_by_name => sub { 42 },
    get_host_id         => sub { -1 },
  );
  eval { host_delete('example', 'example.com', 'absent') };
  isa_ok $@, 'SauronAPI::Exception::NotFound';
};

subtest 'host_delete throws Persistence on negative return' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { 7 },
    get_zone_id_by_name => sub { 42 },
    get_host_id         => sub { 99 },
    delete_host         => sub { -1 },
  );
  eval { host_delete('example', 'example.com', 'h1') };
  isa_ok $@, 'SauronAPI::Exception::Persistence';
  like $@->message, qr/Failed to delete host/, 'mentions delete failure';
};

subtest 'host_update throws NotFound when host missing' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { 7 },
    get_zone_id_by_name => sub { 42 },
    get_host_id         => sub { -1 },
  );
  eval { host_update('example', 'example.com', 'absent', { comment => 'x' }) };
  isa_ok $@, 'SauronAPI::Exception::NotFound';
};

subtest 'host_update throws Persistence on negative return' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id       => sub { 7 },
    get_zone_id_by_name => sub { 42 },
    get_host_id         => sub { 99 },
    get_host            => sub { $_[1]{zone} = 42; $_[1]{type} = 1; $_[1]{domain} = 'h1'; return 0; },
    update_host         => sub { -1 },
  );
  eval { host_update('example', 'example.com', 'h1', { comment => 'x' }) };
  isa_ok $@, 'SauronAPI::Exception::Persistence';
  like $@->message, qr/Failed to update host/, 'mentions update failure';
};

subtest 'host_create auto-assign invokes on_ip callback' => sub {
  _reset_mocks;
  my $checked_ip;
  _mock_back_end(
    get_server_id          => sub { 7 },
    get_zone_id_by_name    => sub { 42 },
    get_host_id            => sub { -1 },
    get_net_by_cidr        => sub { 100 },
    get_net                => sub { $_[1]{net} = '10.0.0.0/24'; return 0; },
    get_net_ip_policy      => sub { 0 },
    get_free_ip_by_net     => sub { '10.0.0.42' },
    add_host               => sub { 200 },
    get_host               => sub { $_[1]{zone} = 42; $_[1]{type} = 1; $_[1]{domain} = 'auto'; return 0; },
    get_zone               => sub { $_[1]{server} = 7; return 0; },
    get_server             => sub { $_[1]{name} = 'example'; return 0; },
  );
  _mock_db('SELECT net FROM nets' => []);

  my $on_ip = sub { $checked_ip = $_[0] };
  my $host = eval {
    host_create('example', 'example.com',
      { hostname => 'auto', type => 1, net => '10.0.0.0/24' },
      on_ip => $on_ip);
  };
  ok !$@, 'no exception: ' . ($@ // '');
  is $checked_ip, '10.0.0.42', 'on_ip was called with assigned IP';
  is $host->{domain}, 'auto', 'created host returned';
};

subtest 'host_create on_ip throwing Permission aborts create' => sub {
  _reset_mocks;
  _mock_back_end(
    get_server_id          => sub { 7 },
    get_zone_id_by_name    => sub { 42 },
    get_host_id            => sub { -1 },
    ip_in_use              => sub { 0 },
  );
  my $on_ip = sub { SauronAPI::Exception::Permission->throw(message => 'denied') };
  eval {
    host_create('example', 'example.com',
      { hostname => 'x', type => 1, ips => ['10.0.0.5'] },
      on_ip => $on_ip);
  };
  isa_ok $@, 'SauronAPI::Exception::Permission';
  is $@->http_status, 403, '403 status';
};

_reset_mocks;
done_testing;
