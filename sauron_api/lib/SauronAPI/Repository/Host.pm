package SauronAPI::Repository::Host;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  host_list host_find host_create host_update host_delete host_copy host_move
);

use Sauron::BackEnd ();
use Sauron::Util   qw(is_cidr);
use SauronAPI::Codecs       qw(mx value);
use SauronAPI::Exception    ();
use SauronAPI::FieldCodec;
use SauronAPI::Repository   qw(dbq check_rc);
use JSON::PP ();

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
  iaid flags prn wks mx rp_mbox rp_txt domain net loc
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

my @LIST_COLUMNS = qw(
  id domain type ttl class grp alias cname_txt hinfo_hw hinfo_sw
  router ether info location dept huser email model serial misc
  asset_id comment duid iaid cdate cuser mdate muser
);

sub host_list {
  my ($server_id, $zone_id, %opts) = @_;

  my $page     = $opts{page}     // 1;
  my $per_page = $opts{per_page} // 50;
  my $offset   = ($page - 1) * $per_page;

  my $rows = dbq(
    "SELECT " . join(',', @LIST_COLUMNS) . " FROM hosts " .
    "WHERE zone=? ORDER BY domain LIMIT ? OFFSET ?",
    $zone_id, $per_page, $offset
  );

  # Batch-fetch IPs from a_entries for the returned host IDs
  my %host_ips;
  if (@$rows) {
    my @host_ids = map $_->[0], @$rows;
    my $placeholders = join ',', ('?') x @host_ids;
    my $ip_rows = dbq(
      "SELECT host, ip FROM a_entries WHERE host IN ($placeholders) ORDER BY host, ip",
      @host_ids
    );
    for my $row (@$ip_rows) {
      push @{$host_ips{$row->[0]}}, $row->[1];
    }
  }

  my @data;
  for my $row (@$rows) {
    push @data, _build_host_list_item($zone_id, $server_id, $row, $host_ips{$row->[0]});
  }

  my $total_rows = dbq(
    "SELECT COUNT(*) FROM hosts WHERE zone=?",
    $zone_id
  );
  my $total = $total_rows->[0][0] // 0;

  my $total_pages = $per_page > 0 ? int(($total + $per_page - 1) / $per_page) : 0;

  my $metadata = {
    pagination => {
      total       => $total,
      page        => $page,
      per_page    => $per_page,
      total_pages => $total_pages,
    },
    sort    => [],
    filters => [],
  };

  return (\@data, $metadata);
}

sub _build_host_list_item {
  my ($zone_id, $server_id, $row, $ips) = @_;

  my %item;
  @item{@LIST_COLUMNS} = @$row;
  $item{cuser} =~ s/\s+$// if defined $item{cuser};
  $item{muser} =~ s/\s+$// if defined $item{muser};
  $item{zone_id} = $zone_id;
  $item{server_id} = $server_id;
  $item{ips} = $ips // [];
  return \%item;
}

sub host_find {
  my ($server_id, $zone_id, $hostname) = @_;

  my $host_id = _host_id($zone_id, $hostname);
  my %host_data;
  check_rc(Sauron::BackEnd::get_host($host_id, \%host_data),
         'Failed to retrieve host data');

  return _build_host_response($host_id, \%host_data, $zone_id, $server_id);
}

sub host_create {
  my ($server_id, $zone_id, $input, %opts) = @_;

  my $hostname = $input->{hostname}
    or SauronAPI::Exception->validation("'hostname' is required");

  my $existing_id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  if ($existing_id > 0) {
    SauronAPI::Exception->conflict(
      "Host '$hostname' already exists in this zone (id=$existing_id)"
    );
  }

  my $type = $input->{type} // 1;

  if (my $err = _validate_type_fields($input, $type)) {
    SauronAPI::Exception->validation($err);
  }

  # BackEnd::add_host reads only the scalar 'alias' for type 7 and would
  # silently drop an alias_a array; reject it instead of losing data.
  if ($type == 7 && exists $input->{alias_a}) {
    SauronAPI::Exception->validation(
      "Field 'alias_a' cannot be used when creating a type 7 host; " .
      "set the AREC target with 'alias' (host ID). " .
      "Additional targets can be added via update."
    );
  }

  my %rec = (
    zone   => $zone_id,
    domain => $hostname,
    type   => $type,
  );
  _copy_host_fields(\%rec, $input);

  # TODO: when creating an alias (alias > 0) and ttl is not provided,
  # inherit the source host's TTL to match legacy CGI behaviour.
  # The frontend currently sends ttl explicitly; move that rule here.

  _resolve_ips_for_create(\%rec, $input, $server_id, $type, $opts{on_ip});

  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';
    next unless exists $input->{$field};
    my $data = $FIELDS{$field}->encode_create($input->{$field});
    next unless ref $data eq 'ARRAY';
    $rec{$field} = $data;
  }

  my $host_id = _add_host(\%rec);

  my %host_data;
  check_rc(Sauron::BackEnd::get_host($host_id, \%host_data),
         'Host created but failed to retrieve data');

  return _build_host_response($host_id, \%host_data, $zone_id, $server_id);
}

sub host_update {
  my ($server_id, $zone_id, $hostname, $input) = @_;

  my $host_id = _host_id($zone_id, $hostname);

  my %host_data;
  check_rc(Sauron::BackEnd::get_host($host_id, \%host_data),
         'Failed to retrieve host data');

  if (exists $input->{type} && $input->{type} != $host_data{type}) {
    my $from = $host_data{type};
    my $to   = $input->{type};
    unless (($from == 1 && $to == 101) || ($from == 101 && $to == 1)) {
      SauronAPI::Exception->validation("'type' is immutable after creation");
    }
  }

  if (my $err = _validate_type_fields($input, $host_data{type})) {
    SauronAPI::Exception->validation($err);
  }

  my %rec = (
    id     => $host_id,
    zone   => $host_data{zone},
    type   => $host_data{type},
    domain => $host_data{domain},
  );
  _copy_host_fields(\%rec, $input);

  # Always carry existing IPs so BackEnd validation (host_required_data_error)
  # does not reject the update when ip field is absent from the request body.
  $rec{ip} = $host_data{ip};
  if (exists $input->{ips}) {
    my $data = $FIELDS{ip}->encode_update(
      _normalize_ip_entries($input->{ips}), $host_data{ip});
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
    SauronAPI::Exception->persistence(
      "Failed to update host (code: $res)"
    );
  }

  if (Sauron::BackEnd::get_host($host_id, \%host_data) != 0) {
    SauronAPI::Exception->persistence(
      'Host updated but failed to retrieve data'
    );
  }

  return _build_host_response($host_id, \%host_data, $host_data{zone}, $server_id);
}

sub host_delete {
  my ($server_id, $zone_id, $hostname) = @_;

  my $host_id = _host_id($zone_id, $hostname);

  my $res = Sauron::BackEnd::delete_host($host_id);
  if ($res < 0) {
    SauronAPI::Exception->persistence(
      "Failed to delete host (code: $res)"
    );
  }
  return;
}

sub host_copy {
  my ($server_id, $zone_id, $source_hostname, $input, %opts) = @_;

  my $source_id = _host_id($zone_id, $source_hostname);
  my %source;
  check_rc(Sauron::BackEnd::get_host($source_id, \%source),
         'Failed to retrieve source host data');

  # Determine effective type for validation
  my $effective_type = exists $input->{type} ? $input->{type} : $source{type};

  # Validate array fields against the effective type (parity with host_create)
  if (my $err = _validate_type_fields($input, $effective_type)) {
    SauronAPI::Exception->validation($err);
  }

  # Build new record from source + overrides
  my %rec = (
    zone   => $zone_id,
    domain => $source{domain},
    type   => $source{type},
  );

  # Copy scalar fields from source, apply overrides
  my @scalar = qw(
    domain ttl type class grp alias cname_txt hinfo_hw hinfo_sw loc router
    info location dept huser email model misc comment
    flags expiration prn wks mx rp_mbox rp_txt
  );
  for my $f (@scalar) {
    if (exists $input->{$f}) {
      $rec{$f} = $input->{$f};
    } elsif (defined $source{$f}) {
      $rec{$f} = $source{$f};
    }
  }

  # Device-specific fields are never copied from source (matching CGI's
  # copy behaviour), but an explicit value in the request is honoured.
  for my $f (qw(ether duid iaid serial asset_id)) {
    $rec{$f} = $input->{$f}
      if defined $input->{$f} && $input->{$f} ne '';
  }

  # Hostname: auto-generate or use input
  if (my $hn = $input->{hostname}) {
    my $existing = Sauron::BackEnd::get_host_id($zone_id, $hn);
    if ($existing > 0) {
      SauronAPI::Exception->conflict(
        "Host '$hn' already exists in this zone (id=$existing)"
      );
    }
    $rec{domain} = $hn;
  } else {
    $rec{domain} = _auto_hostname($zone_id, $source{domain});
  }

  # IPs: use input, or auto-assign from source's first IP network
  if (exists $input->{ips} || exists $input->{net}) {
    _resolve_ips_for_create(\%rec, $input, $server_id, $rec{type}, $opts{on_ip});
  } elsif ($effective_type == 1 || $effective_type == 6 || $effective_type == 9 || $effective_type == 101) {
    # Auto-assign IP from source's network (CGI copy behaviour).
    my $first_ip;
    if (ref $source{ip} eq 'ARRAY' && @{$source{ip}} > 1) {
      $first_ip = $source{ip}[1][1];
    }
    unless ($first_ip) {
      SauronAPI::Exception->validation(
        "Cannot auto-assign IP: source host has no IP addresses; provide 'ips' or 'net' explicitly"
      );
    }
    my $cidr = Sauron::BackEnd::get_net_cidr_by_ip($server_id, $first_ip);
    unless ($cidr) {
      SauronAPI::Exception->validation(
        "Cannot auto-assign IP: source IP '$first_ip' is not in any known network; provide 'ips' or 'net' explicitly"
      );
    }
    my $policy = Sauron::BackEnd::get_net_ip_policy($server_id, $cidr);
    my $ip = Sauron::BackEnd::get_free_ip_by_net($server_id, $cidr, $rec{ether} // '', '', $policy);
    unless (is_cidr($ip)) {
      SauronAPI::Exception->validation(
        "Cannot auto-assign IP from network '$cidr': $ip"
      );
    }
    $opts{on_ip}->($ip) if $opts{on_ip};
    my $data = $FIELDS{ip}->encode_create([[$ip, 't', 't']]);
    $rec{ip} = $data if ref $data eq 'ARRAY';
  }

  # Array fields from source, overridden by input. Source arrays that are
  # not valid for the effective type are dropped (a type override would
  # otherwise build a hybrid record).
  my %valid_for_type = map { $_ => 1 } @{$TYPE_FIELDS{$effective_type} // []};
  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';
    if (exists $input->{$field}) {
      my $data = $FIELDS{$field}->encode_create($input->{$field});
      $rec{$field} = $data if ref $data eq 'ARRAY';
    } elsif (ref $source{$field} eq 'ARRAY' && @{$source{$field}} > 1) {
      next unless $valid_for_type{$field};
      my $decoded = $FIELDS{$field}->decode($source{$field});
      my $data = $FIELDS{$field}->encode_create($decoded);
      $rec{$field} = $data if ref $data eq 'ARRAY';
    }
  }

  # Let the controller inspect the final merged record (e.g. RHF check).
  $opts{on_merged}->(\%rec) if $opts{on_merged};

  my $host_id = _add_host(\%rec);

  my %host_data;
  check_rc(Sauron::BackEnd::get_host($host_id, \%host_data),
         'Host created but failed to retrieve data');

  return _build_host_response($host_id, \%host_data, $zone_id, $server_id);
}

sub _auto_hostname {
  my ($zone_id, $domain) = @_;

  my ($prefix, $suffix);
  if ($domain =~ /^([^\.]+)(\..*)?$/) {
    $prefix = $1;
    $suffix = $2 // '';
  } else {
    $prefix = $domain;
    $suffix = '';
  }

  my $candidate;
  if ($prefix =~ /(\d+)$/) {
    my $num = $1;
    my $fmt = '%0' . length($num) . 'd';
    do {
      $num++;
      (my $new_prefix = $prefix) =~ s/\Q$1\E$/sprintf($fmt, $num)/e;
      $candidate = $new_prefix . $suffix;
    } while (Sauron::BackEnd::get_host_id($zone_id, $candidate) > 0);
  } else {
    my $n = 2;
    do {
      $candidate = $prefix . $n . $suffix;
      $n++;
    } while (Sauron::BackEnd::get_host_id($zone_id, $candidate) > 0);
  }

  return $candidate;
}

sub host_move {
  my ($server_id, $zone_id, $hostname, $input, %opts) = @_;

  my $host_id = _host_id($zone_id, $hostname);
  my %host;
  check_rc(Sauron::BackEnd::get_host($host_id, \%host),
         'Failed to retrieve host data');

  if ($host{type} != 1) {
    SauronAPI::Exception->validation("Move is only available for host type 1");
  }

  my $has_ip   = exists $input->{ip};
  my $has_net  = exists $input->{net};
  my $has_zone = exists $input->{zone};

  if ($has_zone && ($has_ip || $has_net)) {
    SauronAPI::Exception->validation("Cannot combine zone move with ip/net");
  }
  if ($has_ip && $has_net) {
    SauronAPI::Exception->validation("'ip' and 'net' are mutually exclusive");
  }
  unless ($has_ip || $has_net || $has_zone) {
    SauronAPI::Exception->validation("One of 'ip', 'net', or 'zone' is required");
  }

  if ($has_ip || $has_net) {
    return _move_ip($server_id, $zone_id, $host_id, \%host, $input, \%opts);
  } else {
    return _move_zone($server_id, $zone_id, $host_id, \%host, $input, \%opts);
  }
}

sub _move_ip {
  my ($server_id, $zone_id, $host_id, $host, $input, $opts) = @_;

  my $new_ip;
  if (exists $input->{net}) {
    my $net = $input->{net};
    my $cidr;
    my $net_id = Sauron::BackEnd::get_net_by_cidr($server_id, $net);
    if ($net_id > 0) {
      my %net_data;
      Sauron::BackEnd::get_net($net_id, \%net_data);
      $cidr = $net_data{net};
    } else {
      my $q = dbq("SELECT net FROM nets WHERE server=? AND netname=?",
                  $server_id, $net);
      $cidr = $q->[0][0] if @$q > 0;
    }
    unless ($cidr) {
      SauronAPI::Exception->validation("Network '$net' not found on this server");
    }
    my $policy = Sauron::BackEnd::get_net_ip_policy($server_id, $cidr);
    $new_ip = Sauron::BackEnd::get_free_ip_by_net(
      $server_id, $cidr, $host->{ether} // '', undef, $policy
    );
    unless (is_cidr($new_ip)) {
      SauronAPI::Exception->validation("IP assignment failed: $new_ip");
    }
  } else {
    $new_ip = $input->{ip};
    unless (is_cidr($new_ip)) {
      SauronAPI::Exception->validation("Invalid IP address '$new_ip'");
    }
  }

  $opts->{on_ip}->($new_ip) if $opts->{on_ip};

  if (Sauron::BackEnd::ip_in_use($server_id, $new_ip) > 0) {
    SauronAPI::Exception->conflict("IP '$new_ip' is already in use");
  }

  my @ips = @{$host->{ip}};
  my $from_ip = $input->{from_ip};
  my $found_idx;
  if ($from_ip) {
    for my $i (1 .. $#ips) {
      if ($ips[$i][1] eq $from_ip) { $found_idx = $i; last; }
    }
    SauronAPI::Exception->validation("IP '$from_ip' not found on this host")
      unless $found_idx;
  } else {
    if (@ips > 2) {
      SauronAPI::Exception->validation(
        "Host has multiple IPs; 'from_ip' is required to specify which to move"
      );
    }
    $found_idx = 1;
  }

  $ips[$found_idx][1] = $new_ip;
  $ips[$found_idx][4] = 1;

  my %rec = (
    id     => $host_id,
    zone   => $host->{zone},
    type   => $host->{type},
    domain => $host->{domain},
    ip     => \@ips,
  );

  my $res = Sauron::BackEnd::update_host(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence("Failed to move host (code: $res)");
  }

  my %updated;
  check_rc(Sauron::BackEnd::get_host($host_id, \%updated),
         'Host moved but failed to retrieve data');
  return _build_host_response($host_id, \%updated, $host->{zone}, $server_id);
}

sub _move_zone {
  my ($server_id, $zone_id, $host_id, $host, $input, $opts) = @_;

  my $target_zone = $input->{zone};
  my $new_zone_id = Sauron::BackEnd::get_zone_id($target_zone, $server_id);
  if ($new_zone_id <= 0) {
    SauronAPI::Exception->not_found("Zone '$target_zone' not found on this server");
  }

  if ($new_zone_id == $zone_id) {
    SauronAPI::Exception->validation("Cannot move to the same zone");
  }

  # Pre-check: hostname must not conflict in the target zone (409 per spec).
  my $existing = Sauron::BackEnd::get_host_id($new_zone_id, $host->{domain});
  if ($existing > 0 && $existing != $host_id) {
    SauronAPI::Exception->conflict(
      "Host '$host->{domain}' already exists in zone '$target_zone' (id=$existing)"
    );
  }

  my %rec = (
    id     => $host_id,
    zone   => $new_zone_id,
    type   => $host->{type},
    domain => $host->{domain},
    mx     => -1,
  );

  $rec{ip} = $host->{ip} if ref $host->{ip} eq 'ARRAY';

  my $res = Sauron::BackEnd::update_host(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence("Failed to move host (code: $res)");
  }

  my %updated;
  check_rc(Sauron::BackEnd::get_host($host_id, \%updated),
         'Host moved but failed to retrieve data');
  return _build_host_response($host_id, \%updated, $new_zone_id, $server_id);
}

# ---------------------------------------------------------------------------
# Internal helpers (continued)
# ---------------------------------------------------------------------------

sub _host_id {
  my ($zone_id, $hostname) = @_;
  my $id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  SauronAPI::Exception->not_found(
    "Host '$hostname' not found in zone"
  ) if $id <= 0;
  return $id;
}

# add_host returns -27 when required data for the host type is missing
# (e.g. type 1 without IPs) — a client error, so map it to 400 with the
# BackEnd's own explanation instead of a generic 500.
sub _add_host {
  my ($rec) = @_;
  my $host_id = Sauron::BackEnd::add_host($rec);
  if ($host_id == -27) {
    my $err = Sauron::BackEnd::host_required_data_error($rec);
    SauronAPI::Exception->validation(
      ($err && $err ne '') ? $err : "Missing required data for host type $rec->{type}"
    );
  }
  if ($host_id < 0) {
    SauronAPI::Exception->persistence(
      "Failed to create host (code: $host_id)"
    );
  }
  return $host_id;
}

sub _copy_host_fields {
  my ($rec, $json) = @_;
  my @scalar_fields = qw(
    domain ttl type class grp alias cname_txt hinfo_hw hinfo_sw router ether ether_alias
    info location dept huser email model serial misc asset_id comment duid
    iaid flags expiration prn wks mx rp_mbox rp_txt loc
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
    unless ($type == 1 || $type == 101) {
      SauronAPI::Exception->validation(
        "Auto-assignment ('net') is only valid for host types 1 and 101"
      );
    }
  }

  if ($net and defined $ips) {
    SauronAPI::Exception->validation(
      "Provide either 'net' (auto-assign) or 'ips' (manual), not both"
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
      my $q = dbq("SELECT net FROM nets WHERE server=? AND netname=?",
                  $server_id, $net);
      $cidr = $q->[0][0] if @$q > 0;
    }
    unless ($cidr) {
      SauronAPI::Exception->validation(
        "Network '$net' not found on this server"
      );
    }

    my $ip_policy = Sauron::BackEnd::get_net_ip_policy($server_id, $cidr);
    my $ip = Sauron::BackEnd::get_free_ip_by_net(
      $server_id, $cidr, $rec->{ether} // '', undef, $ip_policy
    );
    unless (is_cidr($ip)) {
      SauronAPI::Exception->validation(
        "IP assignment failed: $ip"
      );
    }
    $on_ip->($ip) if $on_ip;
    my $data = $FIELDS{ip}->encode_create([[$ip, 't', 't']]);
    $rec->{ip} = $data if ref $data eq 'ARRAY';
    return;
  }

  if (defined $ips) {
    my $triples = _normalize_ip_entries($ips);
    for my $triple (@$triples) {
      my $ip = $triple->[0];
      unless (is_cidr($ip)) {
        SauronAPI::Exception->validation(
          "Invalid IP address '$ip'"
        );
      }
      if (Sauron::BackEnd::ip_in_use($server_id, $ip) > 0) {
        SauronAPI::Exception->conflict(
          "IP address '$ip' is already in use"
        );
      }
      $on_ip->($ip) if $on_ip;
    }
    my $data = $FIELDS{ip}->encode_create($triples);
    $rec->{ip} = $data if ref $data eq 'ARRAY';
  }
}

# Normalize API ips input ([{ip, reverse?, forward?}, ...]) into marker
# triples [ip, 't'/'f', 't'/'f']. Flags default to true when omitted.
sub _normalize_ip_entries {
  my ($ips) = @_;
  SauronAPI::Exception->validation("'ips' must be an array")
    unless ref $ips eq 'ARRAY';

  my @out;
  for my $entry (@$ips) {
    SauronAPI::Exception->validation(
      "Each 'ips' item must be an object with an 'ip' field"
    ) unless ref $entry eq 'HASH' && defined $entry->{ip} && length $entry->{ip};
    my $rev = exists $entry->{reverse} ? ($entry->{reverse} ? 't' : 'f') : 't';
    my $fwd = exists $entry->{forward} ? ($entry->{forward} ? 't' : 'f') : 't';
    push @out, [$entry->{ip}, $rev, $fwd];
  }
  return \@out;
}

# ---------------------------------------------------------------------------
# Response builder (was _build_host_response in controller)
# ---------------------------------------------------------------------------

sub _build_host_response {
  my ($host_id, $host_data, $zone_id, $server_id) = @_;

  my $server_name = '';
  if ($server_id) {
    my %server_data;
    if (Sauron::BackEnd::get_server($server_id, \%server_data) == 0) {
      $server_name = $server_data{name};
    }
  } elsif ($zone_id > 0) {
    my %zone_data;
    if (Sauron::BackEnd::get_zone($zone_id, \%zone_data) == 0) {
      my $sid = $zone_data{server};
      if ($sid > 0) {
        my %server_data;
        if (Sauron::BackEnd::get_server($sid, \%server_data) == 0) {
          $server_name = $server_data{name};
        }
      }
    }
  }

  my @ips;
  if (ref $host_data->{ip} eq 'ARRAY' && @{$host_data->{ip}} > 1) {
    for my $i (1 .. $#{$host_data->{ip}}) {
      my $r = $host_data->{ip}[$i];
      next unless defined $r->[1];
      push @ips, {
        ip      => $r->[1],
        reverse => ($r->[2] // 'f') eq 't' ? JSON::PP::true : JSON::PP::false,
        forward => ($r->[3] // 'f') eq 't' ? JSON::PP::true : JSON::PP::false,
      };
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
    loc               => $host_data->{loc},
    wks               => $host_data->{wks},
    mx                => $host_data->{mx},
    rp_mbox           => $host_data->{rp_mbox},
    rp_txt            => $host_data->{rp_txt},
    router            => $host_data->{router},
    prn               => defined $host_data->{prn} ? ($host_data->{prn} eq 't' ? JSON::PP::true : JSON::PP::false) : JSON::PP::false,
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

sub _build_ip_record        { [0, $_[0][0], $_[0][1], $_[0][2], 2] }
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
