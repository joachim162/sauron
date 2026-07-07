package SauronAPI::Controller::Server;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::BackEnd ();
use SauronAPI::AuthZ qw(check_perms filter_servers);
use SauronAPI::Codecs qw(aml value forwarder);
use JSON::PP ();

# All scalar fields from get_record("servers", ...) that map to ServerFields schema.
my @SCALAR_FIELDS = qw(
  name comment directory version hostname hostaddr hostmaster
  pzone_path szone_path named_ca pid_file dump_file named_xfer stats_file memstats_file
  ttl refresh retry expire minimum
  forward recursion nnotify dialup multiple_cnames rfc2308_type1 authnxdomain
  checknames_m checknames_s checknames_r
  query_src_ip query_src_port listen_on_port transfer_source
  query_src_ip_v6 query_src_port_v6 listen_on_port_v6 transfer_source_v6
  zones_only no_roots masterserver
  df_port df_max_delay df_max_uupdates df_mclt df_split df_loadbalmax
  df_port6 df_max_delay6 df_max_uupdates6 df_mclt6 df_split6 df_loadbalmax6
  dhcp_flags named_flags dhcp_flags6
);

# Array field keys from get_server.
my @ARRAY_FIELDS = qw(
  allow_transfer allow_query allow_recursion blackhole listen_on listen_on_v6
  allow_query_cache allow_notify forwarders
  dhcp_l dhcp txt logging custom_opts bind_globals dhcp6_l dhcp6
);

# --- Dispatch tables (array field handling) ---

my %FIELDS = (
  allow_transfer    => aml(),
  allow_query       => aml(),
  allow_recursion   => aml(),
  blackhole         => aml(),
  listen_on         => aml(),
  listen_on_v6      => aml(),
  allow_query_cache => aml(),
  allow_notify      => aml(),
  forwarders        => forwarder(with_port => 0),
  dhcp_l            => value(key => 'dhcp', label => 'DHCP'),
  dhcp              => value(key => 'dhcp', label => 'DHCP'),
  txt               => value(key => 'txt',  label => 'TXT'),
  logging           => value(key => 'txt',  label => 'TXT'),
  custom_opts       => value(key => 'txt',  label => 'TXT'),
  bind_globals      => value(key => 'txt',  label => 'TXT'),
  dhcp6_l           => value(key => 'dhcp', label => 'DHCP6'),
  dhcp6             => value(key => 'dhcp', label => 'DHCP6'),
);

# --- Helper functions ---

# Resolve server name to ID, rendering 404 if not found.
# Returns server_id on success, undef on failure (response already rendered).
# TODO: Use the SauronAPI helper get_server_id_or_404 instead.
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

# Copy scalar fields, boolean fields, and decomposed flags from JSON to %rec.
sub _copy_scalar_fields {
  my ($rec, $json) = @_;

  for my $field (@SCALAR_FIELDS) {
    next if $field eq 'dhcp_flags' || $field eq 'named_flags' || $field eq 'dhcp_flags6';
    $rec->{$field} = $json->{$field} if exists $json->{$field};
  }

  # Convert boolean fields
  $rec->{zones_only} = ($json->{zones_only} ? 't' : 'f') if exists $json->{zones_only};
  $rec->{no_roots}   = ($json->{no_roots}   ? 't' : 'f') if exists $json->{no_roots};

  # Decomposed DHCP/named flags
  for my $flag (qw(dhcp_flags_ad dhcp_flags_fo named_flags_ac named_flags_isz
                    named_flags_hinfo named_flags_wks dhcp_flags_ad6 dhcp_flags_fo6)) {
    $rec->{$flag} = $json->{$flag} if exists $json->{$flag};
  }
}

# Map BackEnd server data hash to OpenAPI Server schema.
sub _build_server_response {
  my ($server_id, $server_data) = @_;

  my $response = {
    id          => $server_id,
    lastrun     => $server_data->{lastrun},
    server_type => $server_data->{server_type} // 'Master',
    cdate       => $server_data->{cdate},
    cuser       => $server_data->{cuser},
    mdate       => $server_data->{mdate},
    muser       => $server_data->{muser},
  };

  # Copy all scalar fields from ServerFields
  for my $field (@SCALAR_FIELDS) {
    next if $field eq 'zones_only' || $field eq 'no_roots';
    $response->{$field} = $server_data->{$field}
      if exists $server_data->{$field} && defined $server_data->{$field};
  }

  # Boolean fields (BackEnd stores as 't'/'f' strings)
  $response->{zones_only} = ($server_data->{zones_only} eq 't' ? $JSON::PP::true : $JSON::PP::false) if defined $server_data->{zones_only};
  $response->{no_roots}   = ($server_data->{no_roots}   eq 't' ? $JSON::PP::true : $JSON::PP::false) if defined $server_data->{no_roots};

  # Copy array fields
  for my $field (@ARRAY_FIELDS) {
    if (ref $server_data->{$field} eq 'ARRAY' && @{$server_data->{$field}} > 1) {
      $response->{$field} = $FIELDS{$field}->decode($server_data->{$field});
    }
  }

  return $response;
}

# --- CRUD subroutines ---

# GET /servers
# List all servers managed by Sauron
sub list_servers ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my @ids;
  my %descriptions;

  Sauron::BackEnd::get_server_list(-1, \%descriptions, \@ids);

  my @servers;
  for my $id (@ids) {
    next if $id == -1;

    my %server_data;
    if (Sauron::BackEnd::get_server($id, \%server_data) == 0) {
      push @servers, {
        id      => $id,
        name    => $server_data{name},
        comment => $server_data{comment} // ''
      };
    }
  }

  my $perms = $self->stash('api_perms');
  my $superuser = $self->stash('api_superuser') // 0;
  filter_servers($perms, $superuser, \@servers);

  $self->render(openapi => \@servers);
}

# GET /servers/{server}
# Get server by name
sub get_server ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->_resolve_server or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');

  my %server_data;
  if (Sauron::BackEnd::get_server($server_id, \%server_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to retrieve server data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_server_response($server_id, \%server_data));
}

# POST /servers
# Create a new server
sub add_server ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $json = $self->req->json;

  my $name = $json->{name};
  unless ($name) {
    return $self->render(
      openapi => { error => 'Bad Request', message => "'name' is required" },
      status  => 400
    );
  }

  # Check if server already exists
  my $existing_id = Sauron::BackEnd::get_server_id($name);
  if ($existing_id > 0) {
    return $self->render(
      openapi => { error => 'Conflict', message => "Server '$name' already exists" },
      status  => 409
    );
  }

  my %rec = (name => $name);
  _copy_scalar_fields(\%rec, $json);

  # Copy array fields
  for my $field (@ARRAY_FIELDS) {
    next unless exists $json->{$field};
    my $data = $FIELDS{$field}->encode_create($json->{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $server_id = Sauron::BackEnd::add_server(\%rec);
  if ($server_id < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to create server (code: $server_id)" },
      status  => 500
    );
  }

  my %server_data;
  if (Sauron::BackEnd::get_server($server_id, \%server_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Server created but failed to retrieve data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_server_response($server_id, \%server_data), status => 201);
}

# PUT /servers/{server}
# Update an existing server
sub update_server ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->_resolve_server or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'RW');
  my $json = $self->req->json;

  # Get existing server data
  my %server_data;
  if (Sauron::BackEnd::get_server($server_id, \%server_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to retrieve server data" },
      status  => 500
    );
  }

  my %rec = (id => $server_id);
  _copy_scalar_fields(\%rec, $json);

  # Replace-all semantics for array fields
  for my $field (@ARRAY_FIELDS) {
    next unless exists $json->{$field};

    my $data = $FIELDS{$field}->encode_update($json->{$field}, $server_data{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $res = Sauron::BackEnd::update_server(\%rec);
  if ($res < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to update server (code: $res)" },
      status  => 500
    );
  }

  # Reload server data after update
  if (Sauron::BackEnd::get_server($server_id, \%server_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Server updated but failed to retrieve data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_server_response($server_id, \%server_data));
}

# DELETE /servers/{server}
# Delete a server and all associated data
sub delete_server ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $server_id = $self->_resolve_server or return;

  my $res = Sauron::BackEnd::delete_server($server_id);
  if ($res < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to delete server (code: $res)" },
      status  => 500
    );
  }

  $self->render(openapi => undef, status => 204);
}

1;
