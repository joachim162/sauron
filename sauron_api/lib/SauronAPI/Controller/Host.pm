package SauronAPI::Controller::Host;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::BackEnd ();
use Sauron::DB ();
use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Codecs qw(mx value);
use SauronAPI::FieldCodec;

# Following the same pattern as Server.pm and Zone.pm

my @ARRAY_FIELDS = qw(
  ip ns_l ds_l wks_l mx_l dhcp_l dhcp_l6 printer_l srv_l sshfp_l tlsa_l txt_l
  alias_a subgroups
);

my %FIELDS = (
  ip        => SauronAPI::FieldCodec->new(
    backend_header => ['IP', 'reverse', 'forward'],
    api_columns    => [qw(ip reverse forward)],
    build_row      => sub { [0, $_[0], 't', 't', 2] },
    marker_count   => 4,
  ),
  ns_l      => SauronAPI::FieldCodec->new(
    backend_header => ['NS', 'Comments'],
    api_columns    => [qw(ns comment)],
    build_row      => \&_build_ns_record,
    marker_count   => 3,
  ),
  ds_l      => SauronAPI::FieldCodec->new(
    backend_header => ['Key tag', 'Algorithm', 'Digest type', 'Digest', 'Comments'],
    api_columns    => [qw(key_tag algorithm digest_type digest comment)],
    build_row      => \&_build_ds_record,
    marker_count   => 6,
  ),
  wks_l     => SauronAPI::FieldCodec->new(
    backend_header => ['Proto', 'Services', 'Comments'],
    api_columns    => [qw(proto services comment)],
    build_row      => \&_build_wks_record,
    marker_count   => 4,
  ),
  mx_l      => mx(),
  dhcp_l    => value(key => 'dhcp', label => 'DHCP'),
  dhcp_l6   => value(key => 'dhcp', label => 'DHCP'),
  printer_l => SauronAPI::FieldCodec->new(
    backend_header => ['PRINTER', 'Comments'],
    api_columns    => [qw(printer comment)],
    build_row      => \&_build_printer_record,
    marker_count   => 3,
  ),
  srv_l     => SauronAPI::FieldCodec->new(
    backend_header => ['Priority', 'Weight', 'Port', 'Target', 'Comments'],
    api_columns    => [qw(pri weight port target comment)],
    build_row      => \&_build_srv_record,
    marker_count   => 6,
  ),
  sshfp_l   => SauronAPI::FieldCodec->new(
    backend_header => ['Algorithm', 'Type', 'Fingerprint', 'Comments'],
    api_columns    => [qw(algorithm hashtype fingerprint comment)],
    build_row      => \&_build_sshfp_record,
    marker_count   => 5,
  ),
  tlsa_l    => SauronAPI::FieldCodec->new(
    backend_header => ['Usage', 'Selector', 'Matching Type', 'Asociation Data', 'Comments'],
    api_columns    => [qw(usage selector matching_type association_data comment)],
    build_row      => \&_build_tlsa_record,
    marker_count   => 6,
  ),
  txt_l     => value(key => 'txt', label => 'Text'),
  alias_a   => SauronAPI::FieldCodec->new(
    backend_header => ['Domain'],
    api_columns    => [qw(arec)],
    build_row      => \&_build_alias_a_record,
    marker_count   => 2,
  ),
  subgroups => SauronAPI::FieldCodec->new(
    backend_header => ['SubGroup'],
    api_columns    => [qw(grp)],
    build_row      => \&_build_subgroup_record,
    marker_count   => 2,
  ),
);

# --- Helper functions ---

# Resolve server and zone names to IDs, rendering 404 if not found.
# TODO: Use the SauronAPI helper get_server_id_or_404 for server resolution.
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

sub _copy_host_fields {
  my ($rec, $json) = @_;

  my @scalar_fields = qw(
    domain ttl class grp alias cname_txt hinfo_hw hinfo_sw router ether ether_alias
    info location dept huser email model serial misc asset_id comment duid
    iaid flags expiration prn wks mx rp_mbox rp_txt
  );
  for my $field (@scalar_fields) {
    $rec->{$field} = $json->{$field} if exists $json->{$field};
  }
}

sub _check_rhf {
  my ($c, $json, $is_create) = @_;

  return if $c->stash('api_superuser');

  my $rhf = $c->stash('api_perms')->{rhf} || {};
  return unless keys %$rhf;

  my @missing;
  for my $field (sort keys %$rhf) {
    next unless $rhf->{$field} == 0;
    my $val = $json->{$field};
    if ($is_create) {
      push @missing, $field unless defined $val && $val =~ /\S/;
    } else {
      next unless exists $json->{$field};
      push @missing, $field unless defined $val && $val =~ /\S/;
    }
  }
  return @missing ? \@missing : undef;
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

  $response->{wks_rec} = $host_data->{wks_rec} if exists $host_data->{wks_rec};
  $response->{mx_rec} = $host_data->{mx_rec} if exists $host_data->{mx_rec};
  $response->{grp_rec} = $host_data->{grp_rec} if exists $host_data->{grp_rec};

  # Copy array fields
  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';  # ip is decoded into flat ips array above
    if (ref $host_data->{$field} eq 'ARRAY' && @{$host_data->{$field}} > 1) {
      $response->{$field} = $FIELDS{$field}->decode($host_data->{$field});
    }
  }

  return $response;
}

# --- CRUD subroutines ---

sub list_hosts ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my ($server_id, $zone_id) = _resolve_server_zone($self);
  return unless $server_id;
  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'R');

  my @hosts;
  Sauron::DB::db_query("SELECT id,domain,type FROM hosts WHERE zone=$zone_id ORDER BY domain", \@hosts);

  my @result;
  for my $row (@hosts) {
    push @result, {
      id      => $row->[0],
      domain  => $row->[1],
      type    => $row->[2],
      zone_id => $zone_id,
      fqdn    => '',
    };
  }

  $self->render(openapi => \@result);
}

sub get_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my ($server_id, $zone_id) = _resolve_server_zone($self);
  return unless $server_id;
  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'R');

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

sub add_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my ($server_id, $zone_id) = _resolve_server_zone($self);
  return unless $server_id;
  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'RW');

  my $json = $self->req->json;
  my $hostname = $json->{hostname};
  unless ($hostname) {
    return $self->render(
      openapi => { error => 'Bad Request', message => "'hostname' is required in request body" },
      status  => 400
    );
  }

  my $existing_id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  if ($existing_id > 0) {
    return $self->render(
      openapi => { error => 'Conflict', message => "Host '$hostname' already exists in this zone (id=$existing_id)" },
      status  => 409
    );
  }

  my $type = $json->{type} // 1;

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

  _copy_host_fields(\%rec, $json);

  if (my $missing = _check_rhf($self, $json, 1)) {
    return $self->render(
      openapi => { error => 'Bad Request', message => 'Required fields missing: ' . join(', ', @$missing) },
      status  => 400
    );
  }

  # Translate flat API format ["1.2.3.4"] -> BackEnd ip array field
  if (exists $json->{ips}) {
    my $data = $FIELDS{ip}->encode_create($json->{ips});
    $rec{ip} = $data if ref $data eq 'ARRAY';
  }

  # Build array fields from API input
  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';
    next unless exists $json->{$field};
    my $data = $FIELDS{$field}->encode_create($json->{$field});
    next unless ref $data eq 'ARRAY';
    $rec{$field} = $data;
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

sub delete_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my ($server_id, $zone_id) = _resolve_server_zone($self);
  return unless $server_id;

  my $hostname = $self->param("hostname");
  return unless check_perms($self, type => 'delhost', hostname => $hostname, zone_id => $zone_id, server_id => $server_id);

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

sub update_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my ($server_id, $zone_id) = _resolve_server_zone($self);
  return unless $server_id;

  my $hostname = $self->param("hostname");
  my $json = $self->req->json;

  return unless check_perms($self, type => 'host', hostname => $hostname, zone_id => $zone_id, server_id => $server_id);

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

  _copy_host_fields(\%rec, $json);

  if (my $missing = _check_rhf($self, $json, 0)) {
    return $self->render(
      openapi => { error => 'Bad Request', message => 'Required fields missing: ' . join(', ', @$missing) },
      status  => 400
    );
  }

  if (exists $json->{ips}) {
    my $data = $FIELDS{ip}->encode_update($json->{ips}, $host_data{ip});
    $rec{ip} = $data if ref $data eq 'ARRAY';
  }

  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';
    next unless exists $json->{$field};

    my $data = $FIELDS{$field}->encode_update($json->{$field}, $host_data{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
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

# --- Type-specific field validation ---

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

my %UNIVERSAL_FIELDS = map { $_ => 1 } qw(
  hostname type comment ttl class grp expiration
  alias cname_txt hinfo_hw hinfo_sw router ether ether_alias
  info location dept huser email model serial misc asset_id duid
  iaid flags prn wks mx rp_mbox rp_txt domain
);

sub _validate_type_fields {
  my ($json, $type) = @_;

  my %valid = map { $_ => 1 } @{$TYPE_FIELDS{$type} // []};
  for my $field (keys %$json) {
    next if $UNIVERSAL_FIELDS{$field};
    return "Field '$field' is not valid for host type $type" unless $valid{$field};
  }
  return undef;
}

# --- Record builders ---

sub _build_ns_record {
  my ($obj) = @_;
  return [0, $obj->{ns}, $obj->{comment} // '', 2];
}

sub _build_ds_record {
  my ($obj) = @_;
  return [0, $obj->{key_tag}, $obj->{algorithm}, $obj->{digest_type}, $obj->{digest}, $obj->{comment} // '', 2];
}

sub _build_wks_record {
  my ($obj) = @_;
  return [0, $obj->{proto}, $obj->{services}, $obj->{comment} // '', 2];
}

sub _build_printer_record {
  my ($obj) = @_;
  return [0, $obj->{printer}, $obj->{comment} // '', 2];
}

sub _build_srv_record {
  my ($obj) = @_;
  return [0, $obj->{pri}, $obj->{weight}, $obj->{port}, $obj->{target}, $obj->{comment} // '', 2];
}

sub _build_sshfp_record {
  my ($obj) = @_;
  return [0, $obj->{algorithm}, $obj->{hashtype}, $obj->{fingerprint}, $obj->{comment} // '', 2];
}

sub _build_tlsa_record {
  my ($obj) = @_;
  return [0, $obj->{usage}, $obj->{selector}, $obj->{matching_type}, $obj->{association_data}, $obj->{comment} // '', 2];
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
