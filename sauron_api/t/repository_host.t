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
    my ($sql, $out, @bind) = @_;
    for my $pattern (keys %queries) {
      if (index($sql, $pattern) >= 0) {
        my $handler = $queries{$pattern};
        if (ref $handler eq 'CODE') {
          return $handler->($sql, $out, @bind);
        }
        @$out = @$handler;
        return scalar @$handler;
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

# 29 columns matching Repository::Host @LIST_COLUMNS order.
sub _list_row {
  my ($id, $domain) = @_;
  return [
    $id, $domain, 1, 3600, 'IN', -1, -1, undef, undef, undef,
    0, undef, undef, undef, undef, undef, undef, undef, undef, undef,
    undef, undef, undef, undef, 1000, 'test', 1000, 'test'
  ];
}

subtest 'Exception carries status, kind and message' => sub {
  eval { SauronAPI::Exception->throw(status => 404, kind => 'Not Found', message => 'gone') };
  ok $@, 'exception was thrown';
  isa_ok $@, 'SauronAPI::Exception';
  is $@->status, 404, 'status is 404';
  is $@->kind, 'Not Found', 'kind is "Not Found"';
  is "$@", 'gone', 'stringifies to message';
};

subtest 'Exception shortcut constructors' => sub {
  eval { SauronAPI::Exception->not_found('x') };
  is $@->status, 404, 'not_found -> 404';
  is $@->kind, 'Not Found', 'not_found kind';

  eval { SauronAPI::Exception->validation('x') };
  is $@->status, 400, 'validation -> 400';
  is $@->kind, 'Bad Request', 'validation kind';

  eval { SauronAPI::Exception->forbidden('x') };
  is $@->status, 403, 'forbidden -> 403';
  is $@->kind, 'Forbidden', 'forbidden kind';

  eval { SauronAPI::Exception->conflict('x') };
  is $@->status, 409, 'conflict -> 409';
  is $@->kind, 'Conflict', 'conflict kind';

  eval { SauronAPI::Exception->persistence('x') };
  is $@->status, 500, 'persistence -> 500';
  is $@->kind, 'Internal Server Error', 'persistence kind';
};

subtest 'host_list returns paginated envelope with scalar columns' => sub {
  _reset_mocks;
  _mock_db(
    'ORDER BY domain' => [ _list_row(100, 'a.example'), _list_row(101, 'b.example') ],
    'a_entries'       => [],
    'COUNT(*)'        => [[2]],
  );

  my ($data, $meta) = host_list(7, 42);
  is ref $data, 'ARRAY', 'data is arrayref';
  is scalar @$data, 2, 'two rows';
  is $data->[0]{domain}, 'a.example', 'first row domain';
  is $data->[0]{zone_id}, 42, 'zone_id propagated';
  is $data->[0]{ttl}, 3600, 'scalar column ttl';
  is $data->[0]{cuser}, 'test', 'scalar column cuser';
  is_deeply $data->[0]{ips}, [], 'empty ips when no a_entries';
  is $meta->{pagination}{total}, 2, 'total in metadata';
  is $meta->{pagination}{page}, 1, 'default page 1';
  is $meta->{pagination}{per_page}, 50, 'default per_page 50';
  is $meta->{pagination}{total_pages}, 1, 'total_pages';
  is_deeply $meta->{sort}, [], 'empty sort';
  is_deeply $meta->{filters}, [], 'empty filters';
};

subtest 'host_list binds zone, limit and offset' => sub {
  _reset_mocks;
  my (@list_bind, @count_bind);
  _mock_db(
    'ORDER BY domain' => sub {
      my ($sql, $out, @bind) = @_;
      @list_bind = @bind;
      @$out = ();
      return 0;
    },
    'COUNT(*)' => sub {
      my ($sql, $out, @bind) = @_;
      @count_bind = @bind;
      @$out = ([6]);
      return 1;
    },
  );

  my ($data, $meta) = host_list(7, 42, page => 3, per_page => 2);
  is_deeply \@list_bind, [42, 2, 4], 'zone_id, limit, offset bound in list query';
  is_deeply \@count_bind, [42], 'zone_id bound in count query';
  is $meta->{pagination}{page}, 3, 'page in metadata';
  is $meta->{pagination}{per_page}, 2, 'per_page in metadata';
  is $meta->{pagination}{total_pages}, 3, 'total_pages is 3';
};

subtest 'host_list empty zone gives zero totals' => sub {
  _reset_mocks;
  _mock_db(
    'ORDER BY domain' => [],
    'COUNT(*)'        => [[0]],
  );

  my ($data, $meta) = host_list(7, 42);
  is_deeply $data, [], 'empty data';
  is $meta->{pagination}{total}, 0, 'total is 0';
  is $meta->{pagination}{total_pages}, 0, 'total_pages is 0 for empty zone';
};

subtest 'host_find throws not_found when host missing' => sub {
  _reset_mocks;
  _mock_back_end(
    get_host_id => sub { -1 },
  );
  eval { host_find(7, 42, 'absent') };
  isa_ok $@, 'SauronAPI::Exception';
  is $@->status, 404, 'status 404';
  like $@->message, qr/Host 'absent' not found/, 'message mentions host';
};

subtest 'host_create throws validation when hostname missing' => sub {
  _reset_mocks;
  eval { host_create(7, 42, { type => 1 }) };
  isa_ok $@, 'SauronAPI::Exception';
  is $@->status, 400, 'status 400';
  like $@->message, qr/hostname/, 'mentions hostname';
};

subtest 'host_create throws conflict when hostname already exists' => sub {
  _reset_mocks;
  _mock_back_end(
    get_host_id => sub { 99 },
  );
  eval { host_create(7, 42, { hostname => 'dup', type => 1 }) };
  isa_ok $@, 'SauronAPI::Exception';
  is $@->status, 409, 'status 409';
  like $@->message, qr/already exists/, 'mentions existing host';
};

subtest 'host_create throws validation on type-invalid field' => sub {
  _reset_mocks;
  _mock_back_end(
    get_host_id => sub { -1 },
  );
  eval {
    host_create(7, 42, {
      hostname => 'newone', type => 4, srv_l => [{ pri => 1, weight => 1, port => 80, target => 'x', comment => '' }],
    });
  };
  isa_ok $@, 'SauronAPI::Exception';
  is $@->status, 400, 'status 400';
  like $@->message, qr/srv_l/, 'mentions invalid field srv_l for type 4';
};

subtest 'host_delete throws not_found when host missing' => sub {
  _reset_mocks;
  _mock_back_end(
    get_host_id => sub { -1 },
  );
  eval { host_delete(7, 42, 'absent') };
  isa_ok $@, 'SauronAPI::Exception';
  is $@->status, 404, 'status 404';
};

subtest 'host_delete throws persistence on negative return' => sub {
  _reset_mocks;
  _mock_back_end(
    get_host_id => sub { 99 },
    delete_host => sub { -1 },
  );
  eval { host_delete(7, 42, 'h1') };
  isa_ok $@, 'SauronAPI::Exception';
  is $@->status, 500, 'status 500';
  like $@->message, qr/Failed to delete host/, 'mentions delete failure';
};

subtest 'host_update throws not_found when host missing' => sub {
  _reset_mocks;
  _mock_back_end(
    get_host_id => sub { -1 },
  );
  eval { host_update(7, 42, 'absent', { comment => 'x' }) };
  isa_ok $@, 'SauronAPI::Exception';
  is $@->status, 404, 'status 404';
};

subtest 'host_update throws persistence on negative return' => sub {
  _reset_mocks;
  _mock_back_end(
    get_host_id => sub { 99 },
    get_host    => sub { $_[1]{zone} = 42; $_[1]{type} = 1; $_[1]{domain} = 'h1'; return 0; },
    update_host => sub { -1 },
  );
  eval { host_update(7, 42, 'h1', { comment => 'x' }) };
  isa_ok $@, 'SauronAPI::Exception';
  is $@->status, 500, 'status 500';
  like $@->message, qr/Failed to update host/, 'mentions update failure';
};

subtest 'host_create auto-assign invokes on_ip callback' => sub {
  _reset_mocks;
  my $checked_ip;
  _mock_back_end(
    get_host_id        => sub { -1 },
    get_net_by_cidr    => sub { 100 },
    get_net            => sub { $_[1]{net} = '10.0.0.0/24'; return 0; },
    get_net_ip_policy  => sub { 0 },
    get_free_ip_by_net => sub { '10.0.0.42' },
    add_host           => sub { 200 },
    get_host           => sub { $_[1]{zone} = 42; $_[1]{type} = 1; $_[1]{domain} = 'auto'; return 0; },
    get_server         => sub { $_[1]{name} = 'srv-host-test'; return 0; },
  );

  my $on_ip = sub { $checked_ip = $_[0] };
  my $host = eval {
    host_create(7, 42,
      { hostname => 'auto', type => 1, net => '10.0.0.0/24' },
      on_ip => $on_ip);
  };
  ok !$@, 'no exception: ' . ($@ // '');
  is $checked_ip, '10.0.0.42', 'on_ip was called with assigned IP';
  is $host->{domain}, 'auto', 'created host returned';
  is $host->{server_id}, 7, 'server_id propagated';
};

subtest 'host_create on_ip throwing forbidden aborts create' => sub {
  _reset_mocks;
  _mock_back_end(
    get_host_id => sub { -1 },
    ip_in_use   => sub { 0 },
  );
  my $on_ip = sub { SauronAPI::Exception->forbidden('denied') };
  eval {
    host_create(7, 42,
      { hostname => 'x', type => 1, ips => [{ ip => '10.0.0.5' }] },
      on_ip => $on_ip);
  };
  isa_ok $@, 'SauronAPI::Exception';
  is $@->status, 403, 'status 403';
  is $@->message, 'denied', 'message propagated';
};

subtest 'host_create ips flags default to t,t and explicit flags preserved' => sub {
  _reset_mocks;
  my $captured;
  _mock_back_end(
    get_host_id => sub { -1 },
    ip_in_use   => sub { 0 },
    add_host    => sub { $captured = $_[0]; 200 },
    get_host    => sub { $_[1]{zone} = 42; $_[1]{type} = 1; $_[1]{domain} = 'flags'; return 0; },
    get_server  => sub { $_[1]{name} = 'srv'; return 0; },
  );

  my $host = eval {
    host_create(7, 42, {
      hostname => 'flags', type => 1,
      ips => [
        { ip => '10.0.0.1' },
        { ip => '10.0.0.2', reverse => 0, forward => 0 },
        { ip => '10.0.0.3', reverse => 1, forward => 0 },
      ],
    });
  };
  ok !$@, 'no exception: ' . ($@ // '');
  is_deeply $captured->{ip}, [
    [0, '10.0.0.1', 't', 't', 2],
    [0, '10.0.0.2', 'f', 'f', 2],
    [0, '10.0.0.3', 't', 'f', 2],
  ], 'marker rows carry default and explicit flags';
};

subtest 'host_create rejects malformed ips items' => sub {
  _reset_mocks;
  _mock_back_end( get_host_id => sub { -1 } );
  eval { host_create(7, 42, { hostname => 'x', type => 1, ips => ['10.0.0.5'] }) };
  isa_ok $@, 'SauronAPI::Exception';
  is $@->status, 400, 'plain string item rejected with 400';
};

subtest 'host_find decodes ips into objects with boolean flags' => sub {
  _reset_mocks;
  _mock_back_end(
    get_host_id => sub { 42 },
    get_host    => sub {
      $_[1]{zone} = 10; $_[1]{type} = 1; $_[1]{domain} = 'web01';
      $_[1]{ip} = [
        ['IP', 'reverse', 'forward'],
        [7, '10.0.0.9', 't', 'f', 0],
        [8, '10.0.0.10', 'f', 'f', 0],
      ];
      return 0;
    },
    get_server => sub { $_[1]{name} = 'srv'; return 0; },
  );

  my $host = eval { host_find(7, 10, 'web01') };
  ok !$@, 'no exception: ' . ($@ // '');
  is scalar @{$host->{ips}}, 2, 'two ip entries';
  is $host->{ips}[0]{ip}, '10.0.0.9', 'first ip';
  ok $host->{ips}[0]{reverse}, 'first reverse true';
  ok !$host->{ips}[0]{forward}, 'first forward false';
  ok !$host->{ips}[1]{reverse} && !$host->{ips}[1]{forward}, 'second both false';
};

_reset_mocks;
done_testing;
