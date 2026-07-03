package SauronAPI::Controller::Net;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::BackEnd ();
use Sauron::DB ();
use Sauron::Util ();
use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Codecs qw(value);
use JSON::PP ();

my @SCALAR_FIELDS = qw(
  netname name net vlan alevel comment
  range_start range_end ip_policy
  rp_mbox rp_txt
);

my @ARRAY_FIELDS = qw(dhcp_l);

my %FIELDS = (
  dhcp_l => value(key => 'dhcp', label => 'DHCP'),
);

sub _resolve_server {
  my ($self) = @_;

  my $server_name = $self->param("server");
  my $server_id = Sauron::BackEnd::get_server_id($server_name);
  if ($server_id <= 0) {
    $self->render(
      openapi => { error => 'Not Found', message => "Server '$server_name' not found" },
      status  => 404
    );
    return undef;
  }

  return $server_id;
}

sub _resolve_net {
  my ($self, $server_id) = @_;

  my $net_param = $self->param("net");

  my $net_id = Sauron::BackEnd::get_net_by_cidr($server_id, $net_param);
  return $net_id if $net_id > 0;

  my @list;
  Sauron::DB::db_query(
    "SELECT id FROM nets WHERE server=$server_id AND netname=" .
    Sauron::DB::db_encode_str($net_param), \@list
  );
  if (@list > 0 && $list[0][0] > 0) {
    return $list[0][0];
  }

  $self->render(
    openapi => { error => 'Not Found', message => "Network '$net_param' not found on this server" },
    status  => 404
  );
  return undef;
}

sub _copy_scalar_fields {
  my ($rec, $json) = @_;

  for my $field (@SCALAR_FIELDS) {
    next if $field eq 'net';
    $rec->{$field} = $json->{$field} if exists $json->{$field};
  }

  $rec->{net} = $json->{net} if exists $json->{net};
  $rec->{subnet} = ($json->{subnet} ? 't' : 'f') if exists $json->{subnet};
  $rec->{dummy}  = ($json->{dummy}  ? 't' : 'f') if exists $json->{dummy};
  $rec->{no_dhcp} = ($json->{no_dhcp} ? 't' : 'f') if exists $json->{no_dhcp};
  $rec->{private_flag} = $json->{private_flag} ? 1 : 0 if exists $json->{private_flag};
}

sub _build_net_response {
  my ($net_id, $net_data) = @_;

  my $response = {
    id        => $net_id,
    server_id => $net_data->{server},
    netname   => $net_data->{netname},
    name      => $net_data->{name},
    net       => $net_data->{net},
    vlan      => $net_data->{vlan} // -1,
    alevel    => $net_data->{alevel} // 0,
    comment   => $net_data->{comment} // '',
    rp_mbox   => $net_data->{rp_mbox} // '',
    rp_txt    => $net_data->{rp_txt} // '',
    cdate     => $net_data->{cdate},
    cuser     => $net_data->{cuser},
    mdate     => $net_data->{mdate},
    muser     => $net_data->{muser},
  };

  $response->{subnet} = ($net_data->{subnet} eq 't' ? $JSON::PP::true : $JSON::PP::false)
    if defined $net_data->{subnet};
  $response->{dummy} = ($net_data->{dummy} eq 't' ? $JSON::PP::true : $JSON::PP::false)
    if defined $net_data->{dummy};
  $response->{no_dhcp} = ($net_data->{no_dhcp} eq 't' ? $JSON::PP::true : $JSON::PP::false)
    if defined $net_data->{no_dhcp};
  $response->{private_flag} = ($net_data->{private_flag} ? $JSON::PP::true : $JSON::PP::false)
    if defined $net_data->{private_flag};

  $response->{range_start} = $net_data->{range_start} || undef;
  $response->{range_end}   = $net_data->{range_end}   || undef;
  $response->{ip_policy}   = $net_data->{ip_policy}   || undef;

  for my $field (@ARRAY_FIELDS) {
    if (ref $net_data->{$field} eq 'ARRAY') {
      $response->{$field} = $FIELDS{$field}->decode($net_data->{$field});
    }
  }

  return $response;
}

sub list_nets ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->_resolve_server or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');

  my $subnets = $self->param('subnets');

  my $perms = $self->stash('api_perms');
  my $user_alevel = $perms->{alevel} // 0;

  my $list = Sauron::BackEnd::get_net_list($server_id, $subnets, $user_alevel);
  my @nets;

  for my $row (@$list) {
    next unless ref $row eq 'ARRAY' && @$row >= 3;
    my %data;
    if (Sauron::BackEnd::get_net($row->[1], \%data) == 0) {
      push @nets, _build_net_response($row->[1], \%data);
    }
  }

  $self->render(openapi => \@nets);
}

sub get_net ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->_resolve_server or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  my $net_id = $self->_resolve_net($server_id) or return;

  my %net_data;
  if (Sauron::BackEnd::get_net($net_id, \%net_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to retrieve network data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_net_response($net_id, \%net_data));
}

sub add_net ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->_resolve_server or return;
  return unless check_perms($self, type => 'superuser');

  my $json = $self->req->json;

  my $netname = $json->{netname};
  unless ($netname) {
    return $self->render(
      openapi => { error => 'Bad Request', message => "'netname' is required" },
      status  => 400
    );
  }

  my $net_cidr = $json->{net};
  unless ($net_cidr) {
    return $self->render(
      openapi => { error => 'Bad Request', message => "'net' (CIDR) is required" },
      status  => 400
    );
  }

  unless (Sauron::Util::is_cidr($net_cidr)) {
    return $self->render(
      openapi => { error => 'Bad Request', message => "'net' $net_cidr is not a valid CIDR" },
      status  => 400
    );
  }

  my $existing_id = Sauron::BackEnd::get_net_by_cidr($server_id, $net_cidr);
  if ($existing_id > 0) {
    return $self->render(
      openapi => { error => 'Conflict', message => "Network '$net_cidr' already exists on this server" },
      status  => 409
    );
  }

  my %rec = (
    server => $server_id,
    net    => $net_cidr,
  );
  _copy_scalar_fields(\%rec, $json);

  for my $field (@ARRAY_FIELDS) {
    next unless exists $json->{$field};
    my $data = $FIELDS{$field}->encode_create($json->{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $net_id = Sauron::BackEnd::add_net(\%rec);
  if ($net_id < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to create network (code: $net_id)" },
      status  => 500
    );
  }

  my %net_data;
  if (Sauron::BackEnd::get_net($net_id, \%net_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Network created but failed to retrieve data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_net_response($net_id, \%net_data), status => 201);
}

sub update_net ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->_resolve_server or return;
  return unless check_perms($self, type => 'superuser');
  my $net_id = $self->_resolve_net($server_id) or return;

  my $json = $self->req->json;

  my %net_data;
  if (Sauron::BackEnd::get_net($net_id, \%net_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to retrieve existing network data" },
      status  => 500
    );
  }

  my %rec = (id => $net_id, net => $net_data{net});
  _copy_scalar_fields(\%rec, $json);

  for my $field (@ARRAY_FIELDS) {
    next unless exists $json->{$field};
    my $data = $FIELDS{$field}->encode_update($json->{$field}, $net_data{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $res = Sauron::BackEnd::update_net(\%rec);
  if ($res < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to update network (code: $res)" },
      status  => 500
    );
  }

  if (Sauron::BackEnd::get_net($net_id, \%net_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Network updated but failed to retrieve data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_net_response($net_id, \%net_data));
}

sub delete_net ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->_resolve_server or return;
  return unless check_perms($self, type => 'superuser');
  my $net_id = $self->_resolve_net($server_id) or return;

  my $res = Sauron::BackEnd::delete_net($net_id);
  if ($res < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to delete network (code: $res)" },
      status  => 500
    );
  }

  $self->render(openapi => undef, status => 204);
}

1;
