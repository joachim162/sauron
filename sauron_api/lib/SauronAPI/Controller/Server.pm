package SauronAPI::Controller::Server;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Data::Dumper;

use Sauron::BackEnd ();
use JSON::PP ();

# TODO: Test all endpoints

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

my %BACKEND_HEADERS = (
  # AML fields — header is ['aml', 0] (server_id gets set contextually)
  allow_transfer    => ['aml', 0],
  allow_query       => ['aml', 0],
  allow_recursion   => ['aml', 0],
  blackhole         => ['aml', 0],
  listen_on         => ['aml', 0],
  listen_on_v6      => ['aml', 0],
  allow_query_cache => ['aml', 0],
  allow_notify      => ['aml', 0],
  # Forwarders
  forwarders        => ['IP', 'Comments'],
  # Simple text/dhcp fields
  dhcp_l            => ['DHCP', 'Comments'],
  dhcp              => ['DHCP', 'Comments'],
  txt               => ['TXT', 'Comments'],
  logging           => ['TXT', 'Comments'],
  custom_opts       => ['TXT', 'Comments'],
  bind_globals      => ['TXT', 'Comments'],
  dhcp6_l           => ['DHCP6', 'Comments'],
  dhcp6             => ['DHCP6', 'Comments'],
);

# API output column names — used by _strip_marker_format for response mapping.
my %HEADERS = (
  # AML fields — columns from cidr_entries: mode, ip, acl, tkey, op, comment
  allow_transfer    => [qw(mode ip acl tkey op comment)],
  allow_query       => [qw(mode ip acl tkey op comment)],
  allow_recursion   => [qw(mode ip acl tkey op comment)],
  blackhole         => [qw(mode ip acl tkey op comment)],
  listen_on         => [qw(mode ip acl tkey op comment)],
  listen_on_v6      => [qw(mode ip acl tkey op comment)],
  allow_query_cache => [qw(mode ip acl tkey op comment)],
  allow_notify      => [qw(mode ip acl tkey op comment)],
  # Forwarders
  forwarders        => [qw(ip comment)],
  # Simple text/dhcp fields
  dhcp_l            => [qw(dhcp comment)],
  dhcp              => [qw(dhcp comment)],
  txt               => [qw(txt comment)],
  logging           => [qw(txt comment)],
  custom_opts       => [qw(txt comment)],
  bind_globals      => [qw(txt comment)],
  dhcp6_l           => [qw(dhcp comment)],
  dhcp6             => [qw(dhcp comment)],
);

my %BUILDERS = (
  allow_transfer    => \&_build_aml_record,
  allow_query       => \&_build_aml_record,
  allow_recursion   => \&_build_aml_record,
  blackhole         => \&_build_aml_record,
  listen_on         => \&_build_aml_record,
  listen_on_v6      => \&_build_aml_record,
  allow_query_cache => \&_build_aml_record,
  allow_notify      => \&_build_aml_record,
  forwarders        => \&_build_forwarder_record,
  dhcp_l            => \&_build_simple_record,
  dhcp              => \&_build_simple_record,
  txt               => \&_build_simple_record,
  logging           => \&_build_simple_record,
  custom_opts       => \&_build_simple_record,
  bind_globals      => \&_build_simple_record,
  dhcp6_l           => \&_build_simple_record,
  dhcp6             => \&_build_simple_record,
);

# Marker column position for update_array_field in BackEnd.
# AML fields: marker at index 7 (8 columns: id + 6 data + marker).
# Simple/forwarder fields: marker at index 3 (4 columns: id + 2 data + marker).
my %UPDATE_COUNT = (
  allow_transfer    => 7,
  allow_query       => 7,
  allow_recursion   => 7,
  blackhole         => 7,
  listen_on         => 7,
  listen_on_v6      => 7,
  allow_query_cache => 7,
  allow_notify      => 7,
  forwarders        => 3,
  dhcp_l            => 3,
  dhcp              => 3,
  txt               => 3,
  logging           => 3,
  custom_opts       => 3,
  bind_globals      => 3,
  dhcp6_l           => 3,
  dhcp6             => 3,
);

# --- Helper functions ---

# Resolve server name to ID, rendering 404 if not found.
# Returns server_id on success, undef on failure (response already rendered).
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

# Build deletion entries for existing records in BackEnd array field format.
# update_array_field only reads [0] (record id) and [$count] (marker=-1),
# so padding between them can be empty strings.
sub _mark_existing_for_deletion {
  my ($rows, $existing_data, $count) = @_;
  return unless ref $existing_data eq 'ARRAY';

  for my $i (1 .. $#{$existing_data}) {
    my $id = $existing_data->[$i][0];
    next unless $id && $id > 0;
    my @del = ($id, ('') x ($count - 1), -1);
    push @$rows, \@del;
  }
}

sub _build_aml_record {
  my ($obj) = @_;
  return [0, $obj->{mode} // 0, $obj->{ip} // '', $obj->{acl} // 0,
            $obj->{tkey} // 0, $obj->{op} // 0, $obj->{comment} // '', 2];
}

sub _build_forwarder_record {
  my ($obj) = @_;
  return [0, $obj->{ip}, $obj->{comment} // '', 2];
}

sub _build_simple_record {
  my ($obj) = @_;
  my $val = $obj->{dhcp} // $obj->{txt} // '';
  return [0, $val, $obj->{comment} // '', 2];
}

sub _build_array_field {
  my ($api_data, $field_name) = @_;

  return undef unless defined $api_data && ref $api_data eq 'ARRAY';
  return undef unless exists $BACKEND_HEADERS{$field_name};

  my @rows;
  push @rows, $BACKEND_HEADERS{$field_name};

  my $builder = $BUILDERS{$field_name};
  for my $item (@$api_data) {
    push @rows, $builder->($item);
  }

  return \@rows;
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
    $response->{$field} = $server_data->{$field} if exists $server_data->{$field};
  }

  # Boolean fields (BackEnd stores as 't'/'f' strings)
  $response->{zones_only} = ($server_data->{zones_only} eq 't' ? $JSON::PP::true : $JSON::PP::false) if defined $server_data->{zones_only};
  $response->{no_roots}   = ($server_data->{no_roots}   eq 't' ? $JSON::PP::true : $JSON::PP::false) if defined $server_data->{no_roots};

  # Copy array fields — use %HEADERS for clean API column names
  for my $field (@ARRAY_FIELDS) {
    if (ref $server_data->{$field} eq 'ARRAY' && @{$server_data->{$field}} > 1) {
      $response->{$field} = _strip_marker_format($server_data->{$field}, $HEADERS{$field});
    }
  }

  print Dumper($response);
  return $response;
}

# Strip BackEnd marker format from array fields to clean API objects.
# $api_header: clean column names from %HEADERS (not the BackEnd header row).
# Data rows: [id, col1, col2, ..., marker] — id at [0], marker at end.
# AML rows also have extra join columns after the marker (ignored).
sub _strip_marker_format {
  my ($data, $api_header) = @_;
  return [] unless ref $data eq 'ARRAY' && @$data > 1;

  my $ncols = @$api_header;
  my @result;

  for my $i (1 .. $#$data) {
    my @row = @{$data->[$i]};
    shift @row;  # remove id at index 0
    $#row = $ncols - 1;  # keep only $ncols data elements (discard marker + join cols)

    my %obj;
    for my $j (0 .. $ncols - 1) {
      $obj{$api_header->[$j]} = $row[$j] if $j < @row;
    }
    push @result, \%obj;
  }

  return \@result;
}

# --- CRUD subroutines ---

# GET /servers
# List all servers managed by Sauron
sub list_servers ($self) {
  return unless $self->openapi->valid_input;

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

  $self->render(openapi => \@servers);
}

# GET /servers/{server}
# Get server by name
sub get_server ($self) {
  return unless $self->openapi->valid_input;

  my $server_id = $self->_resolve_server or return;

  my %server_data;
  if (Sauron::BackEnd::get_server($server_id, \%server_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to retrieve server data" },
      status  => 500
    );
  }

  print Dumper(\%server_data);
  $self->render(openapi => _build_server_response($server_id, \%server_data));
}

# POST /servers
# Create a new server
sub create_server ($self) {
  return unless $self->openapi->valid_input;

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
    my $data = _build_array_field($json->{$field}, $field);
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

  my $server_id = $self->_resolve_server or return;
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

    my $new = _build_array_field($json->{$field}, $field);
    next unless ref $new eq 'ARRAY';

    my @rows = ($new->[0]);
    _mark_existing_for_deletion(\@rows, $server_data{$field}, $UPDATE_COUNT{$field});
    push @rows, @{$new}[1 .. $#{$new}];
    $rec{$field} = \@rows;
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
