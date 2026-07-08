package SauronAPI::Controller::Net;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::BackEnd ();
use Sauron::DB ();
use Sauron::Sauron ();
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
  my ($net_id, $net_data, $vlan_map) = @_;

  my $vlan_id = $net_data->{vlan} // -1;
  my $vlan_name = undef;
  if ($vlan_map && $vlan_id > 0) {
    $vlan_name = $vlan_map->{$vlan_id};
  }

  my $response = {
    id        => $net_id,
    server_id => $net_data->{server},
    netname   => $net_data->{netname},
    name      => $net_data->{name},
    net       => $net_data->{net},
    vlan      => $vlan_id,
    vlan_name => $vlan_name,
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
  $response->{ip_policy}   = $net_data->{ip_policy}   // undef;

  for my $field (@ARRAY_FIELDS) {
    if (ref $net_data->{$field} eq 'ARRAY') {
      $response->{$field} = $FIELDS{$field}->decode($net_data->{$field});
    }
  }

  return $response;
}

sub _build_net_list_response {
  my ($row, $vlan_map, $include_vlan_names) = @_;

  my $dummy = (defined $row->[6] && ($row->[6] eq 't' || $row->[6] eq '1'));
  my $no_dhcp = (defined $row->[5] && ($row->[5] eq 't' || $row->[5] eq '1'));
  my $subnet = (defined $row->[9] && ($row->[9] eq 't' || $row->[9] eq '1'));
  my $unallocated = (defined $row->[1] && $row->[1] == -1);

  my $dhcp = ($dummy || $unallocated)
    ? undef : ($no_dhcp ? $JSON::PP::false : $JSON::PP::true);

  my $vlan_id = $row->[7] // -1;
  my $vlan_name = undef;
  if ($include_vlan_names && $vlan_id > 0) {
    $vlan_name = $vlan_map->{$vlan_id};
  }

  return {
    id          => $row->[1],
    net         => $row->[0],
    netname     => $row->[3],
    name        => $row->[2],
    subnet      => ($subnet ? $JSON::PP::true : $JSON::PP::false),
    dummy       => ($dummy ? $JSON::PP::true : $JSON::PP::false),
    dhcp        => $dhcp,
    vlan        => $vlan_id,
    vlan_name   => $vlan_name,
    alevel      => $row->[8] // 0,
  };
}

sub list_nets ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');

  # TODO: Add pagination (limit/offset) before this endpoint is used for
  #       large servers. For now the list returns every visible network.

  my $perms = $self->stash('api_perms');
  my $user_alevel = $perms->{alevel} // 0;

  # Unallocated address blocks are only shown to sufficiently
  # authorized users (same gating as the legacy CGI menu entry);
  # otherwise the flag is silently ignored.
  my $free = $self->param('free');
  $free = ($free && $free ne 'false') ? 1 : 0;
  if ($free) {
    $free = 0 unless ($self->stash('api_superuser')
                      || ($user_alevel >= $main::ALEVEL_SHOW_UNALLOCATED_CIDRS));
  }

  my $net_list = Sauron::BackEnd::get_net_list($server_id, 0, $user_alevel, $free);
  my @nets;

  my $include_vlan_names = ($self->stash('api_superuser')
                            || ($user_alevel >= $main::ALEVEL_VLANS));
  my %vlan_map;
  if ($include_vlan_names) {
    Sauron::BackEnd::get_vlan_list($server_id, \%vlan_map, \my @vlan_list);
  }

  for my $row (@$net_list) {
    next unless ref $row eq 'ARRAY' && @$row >= 10;
    push @nets, _build_net_list_response($row, \%vlan_map, $include_vlan_names);
  }

  $self->render(openapi => \@nets);
}

sub get_net ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  my $net_id = $self->_resolve_net($server_id) or return;

  my %net_data;
  if (Sauron::BackEnd::get_net($net_id, \%net_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to retrieve network data" },
      status  => 500
    );
  }

  my $perms = $self->stash('api_perms');
  my $user_alevel = $perms->{alevel} // 0;
  my $include_vlan_names = ($self->stash('api_superuser')
                            || ($user_alevel >= $main::ALEVEL_VLANS));
  my %vlan_map;
  if ($include_vlan_names) {
    Sauron::BackEnd::get_vlan_list($server_id, \%vlan_map, \my @vlan_list);
  }

  $self->render(openapi => _build_net_response($net_id, \%net_data,
                                                $include_vlan_names ? \%vlan_map : undef));
}

sub add_net ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
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

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
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

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
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
