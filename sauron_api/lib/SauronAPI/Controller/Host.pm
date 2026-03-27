package SauronAPI::Controller::Host;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::BackEnd ();

# Resolve server name and zone name to their numeric IDs.
# Returns ($server_id, $zone_id) or renders a 404 error and returns empty list.
sub _resolve_server_zone {
  my ($self) = @_;

  my $server_name = $self->param("server");
  my $zone_name   = $self->param("zone");

  my $server_id = Sauron::BackEnd::get_server_id($server_name);
  if ($server_id <= 0) {
    $self->render(
      openapi => { error => 'Not Found', message => "Server '$server_name' not found" },
      status  => 404
    );
    return;
  }

  my $zone_id = Sauron::BackEnd::get_zone_id_by_name($zone_name);
  if ($zone_id <= 0) {
    $self->render(
      openapi => { error => 'Not Found', message => "Zone '$zone_name' not found" },
      status  => 404
    );
    return;
  }

  return ($server_id, $zone_id);
}

sub _build_host_response {
  my ($host_id, $host_data, $zone_id) = @_;

  my ($server_id, $server_name) = (0, '');
  if ($zone_id > 0) {
    my %zone_data;
    if (Sauron::BackEnd::get_zone($zone_id, \%zone_data) == 0) {
      $server_id = $zone_data{server};
      if ($server_id > 0) {
        my %server_data;
        if (Sauron::BackEnd::get_server($server_id, \%server_data) == 0) {
          $server_name = $server_data{name};
        }
      }
    }
  }

  my @ips;
  if (ref $host_data->{ip} eq 'ARRAY' && @{$host_data->{ip}} > 1) {
    for my $i (1 .. $#{$host_data->{ip}}) {
      push @ips, $host_data->{ip}[$i][1] if defined $host_data->{ip}[$i][1];
    }
  }

  my $response = {
    id             => $host_id,
    domain         => $host_data->{domain},
    fqdn           => $host_data->{fqdn} // '',
    zone_id        => $zone_id,
    server_id      => $server_id,
    server         => $server_name,
    type           => $host_data->{type},
    ttl            => $host_data->{ttl},
    class          => $host_data->{class},
    grp            => $host_data->{grp},
    alias          => $host_data->{alias},
    cname_txt      => $host_data->{cname_txt},
    hinfo_hw       => $host_data->{hinfo_hw},
    hinfo_sw       => $host_data->{hinfo_sw},
    wks            => $host_data->{wks},
    mx             => $host_data->{mx},
    rp_mbox        => $host_data->{rp_mbox},
    rp_txt         => $host_data->{rp_txt},
    router         => $host_data->{router},
    prn            => $host_data->{prn},
    ips            => \@ips,
    ether          => $host_data->{ether},
    ether_alias    => $host_data->{ether_alias},
    ether_alias_info => $host_data->{ether_alias_info},
    info           => $host_data->{info},
    location       => $host_data->{location},
    dept           => $host_data->{dept},
    huser          => $host_data->{huser},
    email          => $host_data->{email},
    model          => $host_data->{model},
    serial         => $host_data->{serial},
    misc           => $host_data->{misc},
    asset_id       => $host_data->{asset_id},
    dhcp_date      => $host_data->{dhcp_date},
    dhcp_date_str  => $host_data->{dhcp_date_str},
    dhcp_info      => $host_data->{dhcp_info},
    comment        => $host_data->{comment},
    duid           => $host_data->{duid},
    iaid           => $host_data->{iaid},
    flags          => $host_data->{flags},
    cdate          => $host_data->{cdate},
    cdate_str      => $host_data->{cdate_str},
    cuser          => $host_data->{cuser},
    mdate          => $host_data->{mdate},
    mdate_str      => $host_data->{mdate_str},
    muser          => $host_data->{muser},
    expiration     => $host_data->{expiration},
    card_info      => $host_data->{card_info},
  };

  $response->{alias_d} = $host_data->{alias_d} if exists $host_data->{alias_d};
  $response->{cname_alias} = $host_data->{cname_alias} if exists $host_data->{cname_alias};
  $response->{static_alias} = $host_data->{static_alias} if exists $host_data->{static_alias};

  $response->{ns_l} = $host_data->{ns_l} if exists $host_data->{ns_l};
  $response->{ds_l} = $host_data->{ds_l} if exists $host_data->{ds_l};
  $response->{wks_l} = $host_data->{wks_l} if exists $host_data->{wks_l};
  $response->{mx_l} = $host_data->{mx_l} if exists $host_data->{mx_l};
  $response->{dhcp_l} = $host_data->{dhcp_l} if exists $host_data->{dhcp_l};
  $response->{dhcp_l6} = $host_data->{dhcp_l6} if exists $host_data->{dhcp_l6};
  $response->{printer_l} = $host_data->{printer_l} if exists $host_data->{printer_l};
  $response->{srv_l} = $host_data->{srv_l} if exists $host_data->{srv_l};
  $response->{sshfp_l} = $host_data->{sshfp_l} if exists $host_data->{sshfp_l};
  $response->{tlsa_l} = $host_data->{tlsa_l} if exists $host_data->{tlsa_l};
  $response->{txt_l} = $host_data->{txt_l} if exists $host_data->{txt_l};
  $response->{alias_l} = $host_data->{alias_l} if exists $host_data->{alias_l};
  $response->{subgroups} = $host_data->{subgroups} if exists $host_data->{subgroups};
  $response->{alias_a} = $host_data->{alias_a} if exists $host_data->{alias_a};

  $response->{wks_rec} = $host_data->{wks_rec} if exists $host_data->{wks_rec};
  $response->{mx_rec} = $host_data->{mx_rec} if exists $host_data->{mx_rec};
  $response->{grp_rec} = $host_data->{grp_rec} if exists $host_data->{grp_rec};

  return $response;
}

# GET /servers/{server}/zones/{zone}/hosts/{hostname}
# Get host by server, zone, and hostname
sub get_host ($self) {
  return unless $self->openapi->valid_input;

  my ($server_id, $zone_id) = _resolve_server_zone($self);
  return unless $server_id;

  my $hostname = $self->param("hostname");
  my $host_id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  if ($host_id <= 0) {
    return $self->render(
      openapi => { error => 'Not Found', message => "Host '$hostname' not found in zone" },
      status  => 404
    );
  }

  my %host_data;
  if (Sauron::BackEnd::get_host($host_id, \%host_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to retrieve host data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_host_response($host_id, \%host_data, $zone_id));
}

# POST /servers/{server}/zones/{zone}/hosts/{hostname}
# Create a new host in a specific zone on a specific server
sub add_host ($self) {
  return unless $self->openapi->valid_input;

  my ($server_id, $zone_id) = _resolve_server_zone($self);
  return unless $server_id;

  my $hostname = $self->param("hostname");
  my $json = $self->req->json;

  my $existing_id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  if ($existing_id > 0) {
    return $self->render(
      openapi => { error => 'Conflict', message => "Host '$hostname' already exists in this zone (id=$existing_id)" },
      status  => 409
    );
  }

  my $type = $json->{type} // 1;

  # Validate fields for this host type
  if (my $err = _validate_type_fields($json, $type)) {
    return $self->render(
      openapi => { error => 'Bad Request', message => $err },
      status  => 400
    );
  }

  my %rec = (
    zone   => $zone_id,
    domain => $hostname,
    type   => $type,
  );

  # Scalar fields writable during creation
  my @scalar_fields = qw(
    ttl class grp alias cname_txt hinfo_hw hinfo_sw router ether ether_alias
    info location dept huser email model serial misc asset_id comment duid
    iaid flags expiration prn wks mx rp_mbox rp_txt
  );
  for my $field (@scalar_fields) {
    $rec{$field} = $json->{$field} if exists $json->{$field};
  }

  # Translate flat API format ["1.2.3.4"] -> BackEnd ip array field
  if (exists $json->{ips}) {
    my @rows = (["IP", "reverse", "forward"]);
    for my $ip (@{$json->{ips} // []}) {
      push @rows, [0, $ip, 't', 't', 2];
    }
    $rec{ip} = \@rows;
  }

  # Build array fields from API input
  my @array_fields = qw(ns_l ds_l wks_l mx_l dhcp_l dhcp_l6 printer_l srv_l sshfp_l tlsa_l txt_l subgroups alias_a);
  for my $field (@array_fields) {
    next unless exists $json->{$field};
    my $data = _build_array_field($json->{$field}, $field);
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $host_id = Sauron::BackEnd::add_host(\%rec);
  if ($host_id < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to create host record (code: $host_id)" },
      status  => 500
    );
  }

  my %host_data;
  if (Sauron::BackEnd::get_host($host_id, \%host_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Host created but failed to retrieve data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_host_response($host_id, \%host_data, $zone_id), status => 201);
}

  my $existing_id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  if ($existing_id > 0) {
    return $self->render(
      openapi => { error => 'Conflict', message => "Host '$hostname' already exists in this zone (id=$existing_id)" },
      status  => 409
    );
  }

  my $type = $json->{type} // 1;

  # Validate fields for this host type
  if (my $err = _validate_type_fields($json, $type)) {
    return $self->render(
      openapi => { error => 'Bad Request', message => $err },
      status  => 400
    );
  }

  my %rec = (
    zone   => $zone_id,
    domain => $domain,
    type   => $type,
  );

  # Scalar fields writable during creation
  # TODO: Repeated code
  my @scalar_fields = qw(
    ttl class grp alias cname_txt hinfo_hw hinfo_sw router ether ether_alias
    info location dept huser email model serial misc asset_id comment duid
    iaid flags expiration prn wks mx rp_mbox rp_txt
  );
  for my $field (@scalar_fields) {
    $rec{$field} = $json->{$field} if exists $json->{$field};
  }

  # Translate flat API format ["1.2.3.4"] → BackEnd ip array field
  if (exists $json->{ips}) {
    my @rows = (["IP", "reverse", "forward"]);
    for my $ip (@{$json->{ips} // []}) {
      push @rows, [0, $ip, 't', 't', 2];
    }
    $rec{ip} = \@rows;
  }

  # Build array fields from API input
  my @array_fields = qw(ns_l ds_l wks_l mx_l dhcp_l dhcp_l6 printer_l srv_l sshfp_l tlsa_l txt_l subgroups alias_a);
  for my $field (@array_fields) {
    next unless exists $json->{$field};
    my $data = _build_array_field($json->{$field}, $field);
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $host_id = Sauron::BackEnd::add_host(\%rec);
  if ($host_id < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to create host record (code: $host_id)" },
      status  => 500
    );
  }

  my %host_data;
  if (Sauron::BackEnd::get_host($host_id, \%host_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Host created but failed to retrieve data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_host_response($host_id, \%host_data, $zone_id), status => 201);
}

# DELETE /servers/{server}/zones/{zone}/hosts/{hostname}
# Delete a host from a specific zone on a specific server
sub delete_host ($self) {
  return unless $self->openapi->valid_input;

  my ($server_id, $zone_id) = _resolve_server_zone($self);
  return unless $server_id;

  my $hostname = $self->param("hostname");
  my $host_id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  if ($host_id <= 0) {
    return $self->render(
      openapi => { error => 'Not Found', message => "Host '$hostname' not found in zone" },
      status  => 404
    );
  }

  my $res = Sauron::BackEnd::delete_host($host_id);
  if ($res < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to delete host (code: $res)" },
      status  => 500
    );
  }

  $self->render(openapi => undef, status => 204);
}

# Marker position used by BackEnd::update_array_field for each field.
# This must match the $count parameter in each update_array_field call
# inside Sauron::BackEnd::update_host.
my %UPDATE_COUNT = (
  ip        => 4,
  ns_l      => 3,
  ds_l      => 6,
  wks_l     => 4,
  mx_l      => 4,
  dhcp_l    => 3,
  dhcp_l6   => 3,
  printer_l => 3,
  srv_l     => 6,
  sshfp_l   => 5,
  tlsa_l    => 6,
  txt_l     => 3,
  alias_a   => 2,
  subgroups => 2,
);

# Type-specific field validation.
# Maps each host type to the set of fields valid for that type.
# Universal fields (type, comment, ttl, class, grp, expiration) are
# always allowed and not listed here.
my %TYPE_FIELDS = (
  1   => [qw(ips ether hinfo_hw hinfo_sw mx_l wks_l sshfp_l srv_l txt_l
             dhcp_l dhcp_l6 printer_l ns_l ds_l tlsa_l subgroups)],
  2   => [qw(ns_l ds_l)],
  3   => [qw(mx_l txt_l)],
  4   => [qw(alias cname_txt)],
  5   => [qw(printer_l dhcp_l dhcp_l6 subgroups)],
  6   => [qw(ips)],
  7   => [qw(ips mx_l txt_l alias_a)],
  8   => [qw(srv_l)],
  9   => [qw(ips ether duid iaid)],
  11  => [qw(sshfp_l)],
  12  => [qw(tlsa_l)],
  13  => [qw(txt_l)],
  101 => [qw(ips ether duid iaid)],
);

# Fields allowed for all host types.
my %UNIVERSAL_FIELDS = map { $_ => 1 } qw(type comment ttl class grp expiration);

# Validate that all fields in $json are allowed for $type.
# Returns error message string if invalid, undef if OK.
sub _validate_type_fields {
  my ($json, $type) = @_;

  my %valid = map { $_ => 1 } @{$TYPE_FIELDS{$type} // []};
  for my $field (keys %$json) {
    next if $UNIVERSAL_FIELDS{$field};
    return "Field '$field' is not valid for host type $type" unless $valid{$field};
  }
  return undef;
}

# PUT /servers/{server}/zones/{zone}/hosts/{hostname}
# Update an existing host in a specific zone on a specific server
sub update_host ($self) {
  return unless $self->openapi->valid_input;

  my ($server_id, $zone_id) = _resolve_server_zone($self);
  return unless $server_id;

  my $hostname = $self->param("hostname");
  my $json = $self->req->json;

  my $host_id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  if ($host_id <= 0) {
    return $self->render(
      openapi => { error => 'Not Found', message => "Host '$hostname' not found in zone" },
      status  => 404
    );
  }

  my %host_data;
  if (Sauron::BackEnd::get_host($host_id, \%host_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to retrieve host data" },
      status  => 500
    );
  }

  # Validate fields against the host's existing type
  if (my $err = _validate_type_fields($json, $host_data{type})) {
    return $self->render(
      openapi => { error => 'Bad Request', message => $err },
      status  => 400
    );
  }

  my %rec = (
    id     => $host_id,
    zone   => $host_data{zone},
    type   => $host_data{type},
    domain => $host_data{domain},
  );

  my @scalar_fields = qw(
    ttl class grp alias cname_txt hinfo_hw hinfo_sw router ether ether_alias
    info location dept huser email model serial misc asset_id comment duid
    iaid flags expiration prn wks mx rp_mbox rp_txt
  );
  for my $field (@scalar_fields) {
    $rec{$field} = $json->{$field} if exists $json->{$field};
  }

  # Translate flat API format ["1.2.3.4"] → BackEnd ip array field
  if (exists $json->{ips}) {
    my @rows = (["IP", "reverse", "forward"]);
    _mark_existing_for_deletion(\@rows, $host_data{ip}, $UPDATE_COUNT{ip});
    for my $ip (@{$json->{ips} // []}) {
      push @rows, [0, $ip, 't', 't', 2];
    }
    $rec{ip} = \@rows;
  }

  # Replace-all semantics: delete existing records, then add new ones
  my @array_fields = qw(ns_l ds_l wks_l mx_l dhcp_l dhcp_l6 printer_l srv_l sshfp_l tlsa_l txt_l subgroups alias_a);
  for my $field (@array_fields) {
    next unless exists $json->{$field};

    my $new = _build_array_field($json->{$field}, $field);
    next unless ref $new eq 'ARRAY';

    my @rows = ($new->[0]);
    _mark_existing_for_deletion(\@rows, $host_data{$field}, $UPDATE_COUNT{$field});
    push @rows, @{$new}[1 .. $#{$new}];
    $rec{$field} = \@rows;
  }

  my $res = Sauron::BackEnd::update_host(\%rec);
  if ($res < 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Failed to update host (code: $res)" },
      status  => 500
    );
  }

  if (Sauron::BackEnd::get_host($host_id, \%host_data) != 0) {
    return $self->render(
      openapi => { error => 'Internal Server Error', message => "Host updated but failed to retrieve data" },
      status  => 500
    );
  }

  $self->render(openapi => _build_host_response($host_id, \%host_data, $host_data{zone}));
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

sub _build_array_field {
  my ($api_data, $field_name) = @_;

  return undef unless defined $api_data;
  return undef unless ref $api_data eq 'ARRAY';

  my %headers = (
    sshfp_l   => [qw(Algorithm Type Fingerprint Comments)],
    ns_l      => [qw(NS Comments)],
    ds_l      => ['Key tag', 'Algorithm', 'Digest type', 'Digest', 'Comments'],
    mx_l      => [qw(Priority MX Comments)],
    srv_l     => [qw(Priority Weight Port Target Comments)],
    txt_l     => [qw(Text Comments)],
    wks_l     => [qw(Proto Services Comments)],
    tlsa_l    => ['Usage', 'Selector', 'Matching Type', 'Asociation Data', 'Comments'],
    dhcp_l    => [qw(DHCP Comments)],
    dhcp_l6   => [qw(DHCP Comments)],
    printer_l => [qw(PRINTER Comments)],
    alias_a   => [qw(Domain)],
    subgroups => [qw(SubGroup)],
  );

  my %builders = (
    sshfp_l   => \&_build_sshfp_record,
    ns_l      => \&_build_ns_record,
    ds_l      => \&_build_ds_record,
    mx_l      => \&_build_mx_record,
    srv_l     => \&_build_srv_record,
    txt_l     => \&_build_txt_record,
    wks_l     => \&_build_wks_record,
    tlsa_l    => \&_build_tlsa_record,
    dhcp_l    => \&_build_dhcp_record,
    dhcp_l6   => \&_build_dhcp_record,
    printer_l => \&_build_printer_record,
    alias_a   => \&_build_alias_a_record,
    subgroups => \&_build_subgroup_record,
  );

  return undef unless exists $headers{$field_name};

  my @rows;
  push @rows, $headers{$field_name};

  my $builder = $builders{$field_name};
  for my $item (@$api_data) {
    push @rows, $builder->($item);
  }

  return \@rows;
}

sub _build_sshfp_record {
  my ($obj) = @_;
  return [0, $obj->{algorithm}, $obj->{hashtype}, $obj->{fingerprint}, $obj->{comment} // '', 2];
}

sub _build_ns_record {
  my ($obj) = @_;
  return [0, $obj->{ns}, $obj->{comment} // '', 2];
}

sub _build_ds_record {
  my ($obj) = @_;
  return [0, $obj->{key_tag}, $obj->{algorithm}, $obj->{digest_type}, $obj->{digest}, $obj->{comment} // '', 2];
}

sub _build_mx_record {
  my ($obj) = @_;
  return [0, $obj->{pri}, $obj->{mx}, $obj->{comment} // '', 2];
}

sub _build_srv_record {
  my ($obj) = @_;
  return [0, $obj->{pri}, $obj->{weight}, $obj->{port}, $obj->{target}, $obj->{comment} // '', 2];
}

sub _build_txt_record {
  my ($obj) = @_;
  return [0, $obj->{txt}, $obj->{comment} // '', 2];
}

sub _build_wks_record {
  my ($obj) = @_;
  return [0, $obj->{proto}, $obj->{services}, $obj->{comment} // '', 2];
}

sub _build_tlsa_record {
  my ($obj) = @_;
  return [0, $obj->{usage}, $obj->{selector}, $obj->{matching_type}, $obj->{association_data}, $obj->{comment} // '', 2];
}

sub _build_dhcp_record {
  my ($obj) = @_;
  return [0, $obj->{dhcp}, $obj->{comment} // '', 2];
}

sub _build_printer_record {
  my ($obj) = @_;
  return [0, $obj->{printer}, $obj->{comment} // '', 2];
}

sub _build_alias_a_record {
  my ($obj) = @_;
  return [0, $obj->{arec}, 2];
}

sub _build_subgroup_record {
  my ($obj) = @_;
  return [0, $obj->{grp}, 2];
}

1;
