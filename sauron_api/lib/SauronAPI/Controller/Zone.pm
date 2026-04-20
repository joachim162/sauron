package SauronAPI::Controller::Zone;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::BackEnd ();
use SauronAPI::AuthZ qw(check_perms filter_zones);
use JSON::PP ();

# --- Dispatch tables (array field handling) ---
# Following the same pattern as Server.pm

my @ARRAY_FIELDS = qw(
  allow_update allow_query allow_transfer
  masters also_notify forwarders
  dhcp ns mx txt zentries_ta zentries
);

my %BACKEND_HEADERS = (
  # AML fields
  allow_update      => ['aml', 0],
  allow_query       => ['aml', 0],
  allow_transfer    => ['aml', 0],
  # Simple array fields
  masters           => ['IP', 'Comments'],
  also_notify       => ['IP', 'Comments'],
  forwarders        => ['IP', 'Port', 'Comments'],
  dhcp              => ['DHCP', 'Comments'],
  ns                => ['NS', 'Comments'],
  mx                => ['Priority', 'MX', 'Comments'],
  txt               => ['TXT', 'Comments'],
  zentries_ta       => ['TXT'],
  zentries          => ['TXT', 'Comments'],
);

my %HEADERS = (
  # AML fields — columns from cidr_entries: mode, ip, acl, tkey, op, comment
  allow_update      => [qw(mode ip acl tkey op comment)],
  allow_query       => [qw(mode ip acl tkey op comment)],
  allow_transfer    => [qw(mode ip acl tkey op comment)],
  # Simple array fields
  masters           => [qw(ip comment)],
  also_notify       => [qw(ip comment)],
  forwarders        => [qw(ip port comment)],
  dhcp              => [qw(dhcp comment)],
  ns                => [qw(ns comment)],
  mx                => [qw(pri mx comment)],
  txt               => [qw(txt comment)],
  zentries_ta       => [qw(txt)],
  zentries          => [qw(txt comment)],
);

my %BUILDERS = (
  allow_update      => \&_build_aml_record,
  allow_query       => \&_build_aml_record,
  allow_transfer    => \&_build_aml_record,
  masters           => \&_build_simple_record,
  also_notify       => \&_build_simple_record,
  forwarders        => \&_build_forwarder_record,
  dhcp              => \&_build_simple_record,
  ns                => \&_build_simple_record,
  mx                => \&_build_mx_record,
  txt               => \&_build_simple_record,
  zentries_ta       => \&_build_simple_record,
  zentries          => \&_build_simple_record,
);

my %UPDATE_COUNT = (
  allow_update      => 7,
  allow_query       => 7,
  allow_transfer    => 7,
  masters           => 3,
  also_notify       => 3,
  forwarders        => 4,
  dhcp              => 3,
  ns                => 3,
  mx                => 4,
  txt               => 3,
  zentries_ta       => 2,
  zentries          => 3,
);

# --- Helper functions ---

# Resolve server name to ID, rendering 404 if not found.
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

# Mark existing array field rows for deletion (unified for all field types).
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
  return [0, $obj->{ip}, $obj->{port} // '', $obj->{comment} // '', 2];
}

sub _build_simple_record {
  my ($obj) = @_;
  my $val = $obj->{ns} // $obj->{ip} // $obj->{dhcp} // $obj->{txt} // $obj->{mx} // '';
  return [0, $val, $obj->{comment} // '', 2];
}

sub _build_mx_record {
  my ($obj) = @_;
  return [0, $obj->{pri} // 0, $obj->{mx} // '', $obj->{comment} // '', 2];
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

# Copy scalar fields from JSON to %rec for creation/update.
# Skips immutable fields for updates.
sub _copy_zone_fields {
  my ($rec, $json, $skip_immutable) = @_;

  for my $field (qw(name comment hostmaster ttl refresh retry expire minimum
                     forward nnotify chknames transfer_source transfer_source_v6
                     expiration class)) {
    $rec->{$field} = $json->{$field} if exists $json->{$field};
  }

  # Boolean fields
  if (exists $json->{active}) {
    $rec->{active} = $json->{active} ? 't' : 'f';
  }

  # Immutable fields - only set on creation, not update
  unless ($skip_immutable) {
    if (exists $json->{type}) {
      my $raw_type = $json->{type};
      $rec->{type} = uc(substr($raw_type, 0, 1));
    }
    if (exists $json->{reverse}) {
      $rec->{reverse} = $json->{reverse} ? 't' : 'f';
    }
  }
}

# Map BackEnd zone data hash to OpenAPI Zone schema.
sub _build_zone_response {
  my ($zone_id, $zone_data) = @_;

  my $response = {
    id             => $zone_id,
    server_id      => $zone_data->{server},
    serial         => $zone_data->{serial},
    serial_date    => $zone_data->{serial_date},
    reversenet     => $zone_data->{reversenet},
    dummy          => ($zone_data->{dummy} eq 't' ? $JSON::PP::true : $JSON::PP::false),
    flags          => $zone_data->{flags},
    rdate          => $zone_data->{rdate},
    cdate          => $zone_data->{cdate},
    cuser          => $zone_data->{cuser},
    mdate          => $zone_data->{mdate},
    muser          => $zone_data->{muser},
  };

  # Copy writable fields from ZoneFields
  for my $field (qw(name comment hostmaster ttl refresh retry expire minimum
                     forward nnotify chknames transfer_source transfer_source_v6 expiration)) {
    $response->{$field} = $zone_data->{$field} if exists $zone_data->{$field};
  }

  # Boolean fields (BackEnd stores as 't'/'f')
  $response->{active}  = ($zone_data->{active} eq 't' ? $JSON::PP::true : $JSON::PP::false) if defined $zone_data->{active};
  $response->{reverse} = ($zone_data->{reverse} eq 't' ? $JSON::PP::true : $JSON::PP::false) if defined $zone_data->{reverse};

  # String fields with char codes
  $response->{type} = $zone_data->{type} if exists $zone_data->{type};
  $response->{class} = $zone_data->{class} if exists $zone_data->{class};

  # Copy array fields using _strip_marker_format
  for my $field (@ARRAY_FIELDS) {
    if (ref $zone_data->{$field} eq 'ARRAY' && @{$zone_data->{$field}} > 1) {
      $response->{$field} = _strip_marker_format($zone_data->{$field}, $HEADERS{$field});
    }
  }

  return $response;
}

# --- CRUD subroutines ---

# GET /servers/{server}/zones
# List all zones for a server
sub list_zones ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->_resolve_server or return;

  my $zone_list = Sauron::BackEnd::get_zone_list($server_id, 0, 0, 0);

  my @zones;
  for my $row (@$zone_list) {
    next unless ref $row eq 'ARRAY' && @$row >= 2;
    push @zones, {
      id       => $row->[1],
      name     => $row->[0],
      type     => $row->[2],
      reverse  => ($row->[3] eq 't' ? $JSON::PP::true : $JSON::PP::false),
      comment  => $row->[4] // '',
    };
  }

  my $perms = $self->stash('api_perms');
  my $superuser = $self->stash('api_superuser') // 0;
  filter_zones($perms, $superuser, $server_id, \@zones);

  $self->render(openapi => \@zones);
}

# GET /servers/{server}/zones/{zone}
# Get zone details
sub get_zone ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->_resolve_server or return;

  my $zone_name = $self->param("zone");
  my $zone_id = Sauron::BackEnd::get_zone_id($zone_name, $server_id);
  if ($zone_id <= 0) {
    return $self->render(
      openapi => { error => 'Not Found', message => "Zone '$zone_name' not found" },
      status  => 404
    );
  }

  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'R');

  my %zone_data;
  if (Sauron::BackEnd::get_zone($zone_id, \%zone_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to retrieve zone data" },
      status  => 500
    );
  }
  $self->render(openapi => _build_zone_response($zone_id, \%zone_data));
}

# POST /servers/{server}/zones
# Create a new zone
sub create_zone ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $json = $self->req->json;
  my $server_id = $self->_resolve_server or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'RW');

  my $zone_name = $json->{name};
  unless ($zone_name) {
    return $self->render(
      openapi => { error => 'Bad Request', message => "'name' is required" },
      status  => 400
    );
  }

  my $raw_type = $json->{type} // 'M';
  my $type = uc(substr($raw_type, 0, 1));

  # Check if zone already exists
  my $existing_id = Sauron::BackEnd::get_zone_id($zone_name, $server_id);
  if ($existing_id > 0) {
    return $self->render(
      openapi => { error => 'Conflict', message => "Zone '$zone_name' already exists on this server" },
      status  => 409
    );
  }

  my %rec = (
    server => $server_id,
    name   => $zone_name,
    type   => $type,
  );

  # Handle reverse zones
  my $reverse = $json->{reverse} ? 1 : 0;
  if ($reverse) {
    $rec{reverse} = 't';
    if (Sauron::Util::is_cidr($rec{name}) && $rec{name} =~ /\/\d{1,3}$/) {
      $rec{name} = Sauron::Util::cidr2arpa($rec{name});
    }
    my $new_net = Sauron::Util::arpa2cidr($rec{name});
    if ($new_net eq '0.0.0.0/0' || $new_net eq '') {
      return $self->render(
        openapi => { error => 'Bad Request', message => "Invalid reverse zone name" },
        status  => 400
      );
    }
    $rec{reversenet} = $new_net;
  }

  _copy_zone_fields(\%rec, $json, 0);  # skip_immutable=0 (allow all fields)

  my $zone_id = Sauron::BackEnd::add_zone(\%rec);
  if ($zone_id < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to create zone (code: $zone_id)" },
      status  => 500
    );
  }

  my %zone_data;
  if (Sauron::BackEnd::get_zone($zone_id, \%zone_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Zone created but failed to retrieve data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_zone_response($zone_id, \%zone_data), status => 201);
}

# PUT /servers/{server}/zones/{zone}
# Update an existing zone
sub update_zone ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->_resolve_server or return;
  my $json = $self->req->json;

  my $zone_name = $self->param("zone");
  my $zone_id = Sauron::BackEnd::get_zone_id($zone_name, $server_id);
  if ($zone_id <= 0) {
    return $self->render(
      openapi => { error => 'Not Found', message => "Zone '$zone_name' not found" },
      status  => 404
    );
  }

  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'RW');

  # Reject immutable fields
  for my $field (qw(type reverse serial)) {
    if (exists $json->{$field}) {
      return $self->render(
        openapi => { error => 'Bad Request', message => "Field '$field' is immutable after creation" },
        status  => 400
      );
    }
  }

  my %rec = (id => $zone_id);
  _copy_zone_fields(\%rec, $json, 1);  # skip_immutable=1 (reject type/reverse)

  # Fetch existing zone to get current type and array fields (required by BackEnd::update_zone)
  my %existing_zone;
  if (Sauron::BackEnd::get_zone($zone_id, \%existing_zone) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to fetch existing zone data" },
      status  => 500
    );
  }
  $rec{type} = $existing_zone{type};

  # Replace-all semantics for array fields
  for my $field (@ARRAY_FIELDS) {
    next unless exists $json->{$field};

    my $new = _build_array_field($json->{$field}, $field);
    next unless ref $new eq 'ARRAY';

    my @rows = ($new->[0]);
    _mark_existing_for_deletion(\@rows, $existing_zone{$field}, $UPDATE_COUNT{$field});
    push @rows, @{$new}[1 .. $#{$new}];
    $rec{$field} = \@rows;
  }

  my $res = Sauron::BackEnd::update_zone(\%rec);
  if ($res < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to update zone (code: $res)" },
      status  => 500
    );
  }

  # Reload zone data
  my %zone_data;
  if (Sauron::BackEnd::get_zone($zone_id, \%zone_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Zone updated but failed to retrieve data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_zone_response($zone_id, \%zone_data));
}

# DELETE /servers/{server}/zones/{zone}
# Delete a zone and all associated data
sub delete_zone ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->_resolve_server or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'RWS');

  my $zone_name = $self->param("zone");
  my $zone_id = Sauron::BackEnd::get_zone_id($zone_name, $server_id);
  if ($zone_id <= 0) {
    return $self->render(
      openapi => { error => 'Not Found', message => "Zone '$zone_name' not found" },
      status  => 404
    );
  }

  my $res = Sauron::BackEnd::delete_zone($zone_id);
  if ($res < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to delete zone (code: $res)" },
      status  => 500
    );
  }

  $self->render(openapi => undef, status => 204);
}

1;
