package SauronAPI::Repository::Host;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  host_list host_find host_create host_update host_delete
);

use Sauron::BackEnd ();
use Sauron::DB     ();
use Sauron::Util   qw(is_cidr);
use SauronAPI::Codecs       qw(mx value);
use SauronAPI::Exception    ();
use SauronAPI::Exception::NotFound;
use SauronAPI::Exception::Conflict;
use SauronAPI::Exception::Validation;
use SauronAPI::Exception::Persistence;
use SauronAPI::FieldCodec;

# ---------------------------------------------------------------------------
# Array fields handled by FieldCodec. Controllers MUST NOT touch these.
# ---------------------------------------------------------------------------

my @ARRAY_FIELDS = qw(
  ip ns_l ds_l wks_l mx_l dhcp_l dhcp_l6 printer_l srv_l sshfp_l tlsa_l txt_l
  alias_a subgroups
);

my %FIELDS = (
  ip        => SauronAPI::FieldCodec->new(
    backend_header => ['IP', 'reverse', 'forward'],
    api_columns    => [qw(ip reverse forward)],
    build_row      => \&_build_ip_record,
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

# ---------------------------------------------------------------------------
# Type-specific field validation (was _validate_type_fields in controller)
# ---------------------------------------------------------------------------

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
  iaid flags prn wks mx rp_mbox rp_txt domain net
);

sub _validate_type_fields {
  my ($json, $type) = @_;

  my %valid = map { $_ => 1 } @{$TYPE_FIELDS{$type} // []};
  for my $field (keys %$json) {
    next if $UNIVERSAL_FIELDS{$field};
    return "Field '$field' is not valid for host type $type"
      unless $valid{$field};
  }
  return undef;
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

sub host_list {
  my ($server_name, $zone_name, %opts) = @_;

  my $server_id = _server_id($server_name);
  my $zone_id   = _zone_id($zone_name, $server_id);

  my $page     = $opts{page}     // 1;
  my $per_page = $opts{per_page} // 50;

  my $offset = ($page - 1) * $per_page;

  my @rows;
  my @total_rows;
  Sauron::DB::db_query(
    "SELECT id,domain,type FROM hosts WHERE zone=$zone_id ORDER BY domain",
    \@rows
  );
  Sauron::DB::db_query(
    "SELECT COUNT(*) FROM hosts WHERE zone=$zone_id",
    \@total_rows
  );

  my $total = $total_rows[0][0] // 0;
  my $hi = $#rows < $offset + $per_page - 1 ? $#rows : $offset + $per_page - 1;
  my @page_rows = $offset > $#rows ? () : @rows[$offset .. $hi];

  my @data;
  for my $row (@page_rows) {
    push @data, {
      id      => $row->[0],
      domain  => $row->[1],
      type    => $row->[2],
      zone_id => $zone_id,
      fqdn    => '',
    };
  }

  my $total_pages = $per_page > 0 ? int(($total + $per_page - 1) / $per_page) : 0;
  $total_pages = 1 if $total_pages < 1;

  my $data       = \@data;
  my $metadata   = {
    pagination => {
      total       => $total,
      page        => $page,
      per_page    => $per_page,
      total_pages => $total_pages,
    },
    sort    => [],
    filters => [],
  };

  return ($data, $metadata);
}

sub host_find {
  my ($server_name, $zone_name, $hostname) = @_;

  my $server_id = _server_id($server_name);
  my $zone_id   = _zone_id($zone_name, $server_id);

  my $host_id = _host_id($zone_id, $hostname);
  my %host_data;
  _check(Sauron::BackEnd::get_host($host_id, \%host_data),
         'Failed to retrieve host data');

  return _build_host_response($host_id, \%host_data, $zone_id, $server_id);
}

sub host_create {
  my ($server_name, $zone_name, $input, %opts) = @_;

  my $server_id = _server_id($server_name);
  my $zone_id   = _zone_id($zone_name, $server_id);

  my $hostname = $input->{hostname}
    or SauronAPI::Exception::Validation->throw(message => "'hostname' is required");

  my $existing_id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  if ($existing_id > 0) {
    SauronAPI::Exception::Conflict->throw(
      message => "Host '$hostname' already exists in this zone (id=$existing_id)"
    );
  }

  my $type = $input->{type} // 1;

  if (my $err = _validate_type_fields($input, $type)) {
    SauronAPI::Exception::Validation->throw(message => $err);
  }

  my %rec = (
    zone   => $zone_id,
    domain => $hostname,
    type   => $type,
  );
  _copy_host_fields(\%rec, $input);

  _resolve_ips_for_create(\%rec, $input, $server_id, $type, $opts{on_ip});

  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';
    next unless exists $input->{$field};
    my $data = $FIELDS{$field}->encode_create($input->{$field});
    next unless ref $data eq 'ARRAY';
    $rec{$field} = $data;
  }

  my $host_id = Sauron::BackEnd::add_host(\%rec);
  if ($host_id < 0) {
    SauronAPI::Exception::Persistence->throw(
      message => "Failed to create host record (code: $host_id)"
    );
  }

  my %host_data;
  _check(Sauron::BackEnd::get_host($host_id, \%host_data),
         'Host created but failed to retrieve data');

  return _build_host_response($host_id, \%host_data, $zone_id, $server_id);
}

sub host_update {
  my ($server_name, $zone_name, $hostname, $input) = @_;

  my $server_id = _server_id($server_name);
  my $zone_id   = _zone_id($zone_name, $server_id);

  my $host_id = _host_id($zone_id, $hostname);

  my %host_data;
  _check(Sauron::BackEnd::get_host($host_id, \%host_data),
         'Failed to retrieve host data');

  if (my $err = _validate_type_fields($input, $host_data{type})) {
    SauronAPI::Exception::Validation->throw(message => $err);
  }

  my %rec = (
    id     => $host_id,
    zone   => $host_data{zone},
    type   => $host_data{type},
    domain => $host_data{domain},
  );
  _copy_host_fields(\%rec, $input);

  if (exists $input->{ips}) {
    my $data = $FIELDS{ip}->encode_update($input->{ips}, $host_data{ip});
    $rec{ip} = $data if ref $data eq 'ARRAY';
  }

  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';
    next unless exists $input->{$field};
    my $data = $FIELDS{$field}->encode_update($input->{$field}, $host_data{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $res = Sauron::BackEnd::update_host(\%rec);
  if ($res < 0) {
    SauronAPI::Exception::Persistence->throw(
      message => "Failed to update host (code: $res)"
    );
  }

  if (Sauron::BackEnd::get_host($host_id, \%host_data) != 0) {
    SauronAPI::Exception::Persistence->throw(
      message => 'Host updated but failed to retrieve data'
    );
  }

  return _build_host_response($host_id, \%host_data, $host_data{zone}, $server_id);
}

sub host_delete {
  my ($server_name, $zone_name, $hostname) = @_;

  my $server_id = _server_id($server_name);
  my $zone_id   = _zone_id($zone_name, $server_id);

  my $host_id = _host_id($zone_id, $hostname);

  my $res = Sauron::BackEnd::delete_host($host_id);
  if ($res < 0) {
    SauronAPI::Exception::Persistence->throw(
      message => "Failed to delete host (code: $res)"
    );
  }
  return;
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

sub _server_id {
  my ($name) = @_;
  my $id = Sauron::BackEnd::get_server_id($name);
  SauronAPI::Exception::NotFound->throw(message => "Server '$name' not found")
    if $id <= 0;
  return $id;
}

sub _zone_id {
  my ($name, $server_id) = @_;
  my $id = Sauron::BackEnd::get_zone_id_by_name($name);
  SauronAPI::Exception::NotFound->throw(message => "Zone '$name' not found")
    if $id <= 0;
  return $id;
}

sub _host_id {
  my ($zone_id, $hostname) = @_;
  my $id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  SauronAPI::Exception::NotFound->throw(
    message => "Host '$hostname' not found in zone"
  ) if $id <= 0;
  return $id;
}

sub _check {
  my ($rc, $err) = @_;
  return if $rc == 0;
  SauronAPI::Exception::Persistence->throw(message => $err);
}

sub _copy_host_fields {
  my ($rec, $json) = @_;
  my @scalar_fields = qw(
    domain ttl class grp alias cname_txt hinfo_hw hinfo_hw hinfo_sw router ether ether_alias
    info location dept huser email model serial misc asset_id comment duid
    iaid flags expiration prn wks mx rp_mbox rp_txt
  );
  for my $field (@scalar_fields) {
    $rec->{$field} = $json->{$field} if exists $json->{$field};
  }
}

sub _resolve_ips_for_create {
  my ($rec, $input, $server_id, $type, $on_ip) = @_;

  my $net = $input->{net};
  my $ips = $input->{ips};

  if ($net) {
    unless ($type == 1 || $type == 9 || $type == 101) {
      SauronAPI::Exception::Validation->throw(
        message => "Auto-assignment ('net') is only valid for host types 1, 9, and 101"
      );
    }
  }

  if ($net and defined $ips) {
    SauronAPI::Exception::Validation->throw(
      message => "Provide either 'net' (auto-assign) or 'ips' (manual), not both"
    );
  }

  if ($net) {
    my $cidr;
    my $net_id = Sauron::BackEnd::get_net_by_cidr($server_id, $net);
    if ($net_id > 0) {
      my %net_data;
      Sauron::BackEnd::get_net($net_id, \%net_data);
      $cidr = $net_data{net};
    } else {
      Sauron::DB::db_query(
        "SELECT net FROM nets WHERE server=$server_id AND netname=" .
          Sauron::DB::db_encode_str($net), \my @q
      );
      $cidr = $q[0][0] if @q > 0;
    }
    unless ($cidr) {
      SauronAPI::Exception::Validation->throw(
        message => "Network '$net' not found on this server"
      );
    }

    my $ip_policy = Sauron::BackEnd::get_net_ip_policy($server_id, $cidr);
    my $ip = Sauron::BackEnd::get_free_ip_by_net(
      $server_id, $cidr, $rec->{ether} // '', undef, $ip_policy
    );
    unless (is_cidr($ip)) {
      SauronAPI::Exception::Validation->throw(
        message => "IP assignment failed: $ip"
      );
    }
    $on_ip->($ip) if $on_ip;
    my $data = $FIELDS{ip}->encode_create([$ip]);
    $rec->{ip} = $data if ref $data eq 'ARRAY';
    return;
  }

  if (defined $ips) {
    for my $ip (@$ips) {
      next unless defined $ip && length $ip;
      unless (is_cidr($ip)) {
        SauronAPI::Exception::Validation->throw(
          message => "Invalid IP address '$ip'"
        );
      }
      if (Sauron::BackEnd::ip_in_use($server_id, $ip) > 0) {
        SauronAPI::Exception::Conflict->throw(
          message => "IP address '$ip' is already in use"
        );
      }
      $on_ip->($ip) if $on_ip;
    }
    my $data = $FIELDS{ip}->encode_create($ips);
    $rec->{ip} = $data if ref $data eq 'ARRAY';
  }
}

# ---------------------------------------------------------------------------
# Response builder (was _build_host_response in controller)
# ---------------------------------------------------------------------------

sub _build_host_response {
  my ($host_id, $host_data, $zone_id, $server_id) = @_;

  my $server_name = '';
  if (!$server_id && $zone_id > 0) {
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
    id                => $host_id,
    domain            => $host_data->{domain},
    fqdn              => $host_data->{fqdn} // '',
    zone_id           => $zone_id,
    server_id         => $server_id,
    server            => $server_name,
    type              => $host_data->{type},
    ttl               => $host_data->{ttl},
    class             => $host_data->{class},
    grp               => $host_data->{grp},
    alias             => $host_data->{alias},
    cname_txt         => $host_data->{cname_txt},
    hinfo_hw          => $host_data->{hinfo_hw},
    hinfo_sw          => $host_data->{hinfo_sw},
    wks               => $host_data->{wks},
    mx                => $host_data->{mx},
    rp_mbox           => $host_data->{rp_mbox},
    rp_txt            => $host_data->{rp_txt},
    router            => $host_data->{router},
    prn               => $host_data->{prn},
    ips               => \@ips,
    ether             => $host_data->{ether},
    ether_alias       => $host_data->{ether_alias},
    ether_alias_info  => $host_data->{ether_alias_info},
    info              => $host_data->{info},
    location          => $host_data->{location},
    dept              => $host_data->{dept},
    huser             => $host_data->{huser},
    email             => $host_data->{email},
    model             => $host_data->{model},
    serial            => $host_data->{serial},
    misc              => $host_data->{misc},
    asset_id          => $host_data->{asset_id},
    dhcp_date         => $host_data->{dhcp_date},
    dhcp_date_str     => $host_data->{dhcp_date_str},
    dhcp_info         => $host_data->{dhcp_info},
    comment           => $host_data->{comment},
    duid              => $host_data->{duid},
    iaid              => $host_data->{iaid},
    flags             => $host_data->{flags},
    cdate             => $host_data->{cdate},
    cdate_str         => $host_data->{cdate_str},
    cuser             => $host_data->{cuser},
    mdate             => $host_data->{mdate},
    mdate_str         => $host_data->{mdate_str},
    muser             => $host_data->{muser},
    expiration        => $host_data->{expiration},
    card_info         => $host_data->{card_info},
  };

  $response->{alias_d}        = $host_data->{alias_d}        if exists $host_data->{alias_d};
  $response->{cname_alias}    = $host_data->{cname_alias}    if exists $host_data->{cname_alias};
  $response->{static_alias}   = $host_data->{static_alias}   if exists $host_data->{static_alias};
  $response->{wks_rec}        = $host_data->{wks_rec}        if exists $host_data->{wks_rec};
  $response->{mx_rec}         = $host_data->{mx_rec}         if exists $host_data->{mx_rec};
  $response->{grp_rec}        = $host_data->{grp_rec}        if exists $host_data->{grp_rec};

  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';
    if (ref $host_data->{$field} eq 'ARRAY' && @{$host_data->{$field}} > 1) {
      $response->{$field} = $FIELDS{$field}->decode($host_data->{$field});
    }
  }

  return $response;
}

# ---------------------------------------------------------------------------
# Record builders (private)
# ---------------------------------------------------------------------------

sub _build_ip_record        { [0, $_[0], 't', 't', 2] }
sub _build_ns_record        { [0, $_[0]->{ns},      $_[0]->{comment} // '', 2] }
sub _build_ds_record        { [0, $_[0]->{key_tag}, $_[0]->{algorithm}, $_[0]->{digest_type}, $_[0]->{digest}, $_[0]->{comment} // '', 2] }
sub _build_wks_record       { [0, $_[0]->{proto},   $_[0]->{services}, $_[0]->{comment} // '', 2] }
sub _build_printer_record   { [0, $_[0]->{printer}, $_[0]->{comment} // '', 2] }
sub _build_srv_record       { [0, $_[0]->{pri}, $_[0]->{weight}, $_[0]->{port}, $_[0]->{target}, $_[0]->{comment} // '', 2] }
sub _build_sshfp_record     { [0, $_[0]->{algorithm}, $_[0]->{hashtype}, $_[0]->{fingerprint}, $_[0]->{comment} // '', 2] }
sub _build_tlsa_record      { [0, $_[0]->{usage}, $_[0]->{selector}, $_[0]->{matching_type}, $_[0]->{association_data}, $_[0]->{comment} // '', 2] }
sub _build_alias_a_record   { [0, $_[0]->{arec}, 2] }
sub _build_subgroup_record  { [0, $_[0]->{grp}, 2] }

1;
