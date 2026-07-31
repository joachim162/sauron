package SauronAPI::Repository::Zone;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  zone_list zone_find zone_create zone_update zone_delete
);

use Sauron::BackEnd ();
use Sauron::DB     ();
use Sauron::Util   ();
use SauronAPI::Codecs    qw(aml mx value forwarder);
use SauronAPI::Exception ();
use JSON::PP ();

# ---------------------------------------------------------------------------
# Field tables (moved from SauronAPI::Controller::Zone)
# ---------------------------------------------------------------------------

my @ARRAY_FIELDS = qw(
  allow_update allow_query allow_transfer
  masters also_notify forwarders
  dhcp ns mx txt zentries_ta zentries
);

my %FIELDS = (
  allow_update   => aml(),
  allow_query    => aml(),
  allow_transfer => aml(),
  masters        => value(key => 'ip',   label => 'IP'),
  also_notify    => value(key => 'ip',   label => 'IP'),
  forwarders     => forwarder(with_port => 1),
  dhcp           => value(key => 'dhcp', label => 'DHCP'),
  ns             => value(key => 'ns',   label => 'NS'),
  mx             => mx(),
  txt            => value(key => 'txt',  label => 'TXT'),
  zentries_ta    => value(key => 'txt',  label => 'TXT',   comment => 0),
  zentries       => value(key => 'txt',  label => 'TXT'),
);

my @COPY_FIELDS = qw(
  name comment hostmaster ttl refresh retry expire minimum
  forward nnotify chknames transfer_source transfer_source_v6 expiration class
);

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

sub zone_list {
  my ($server_id) = @_;

  my $rows = _dbq(
    "SELECT name,id,type,reverse,comment FROM zones " .
    "WHERE server=? ORDER BY type,reverse,reversenet,name",
    $server_id
  );

  return [ map { +{
    id        => $_->[1],
    server_id => $server_id,
    name      => $_->[0],
    type      => $_->[2],
    reverse   => (($_->[3] // '') eq 't' ? JSON::PP::true : JSON::PP::false),
    comment   => $_->[4] // '',
  } } @$rows ];
}

sub zone_find {
  my ($zone_id) = @_;

  my %zone_data;
  _check(Sauron::BackEnd::get_zone($zone_id, \%zone_data),
         'Failed to retrieve zone data');

  return _build_zone_response($zone_id, \%zone_data);
}

sub zone_create {
  my ($server_id, $input) = @_;

  my $zone_name = $input->{name}
    or SauronAPI::Exception->validation("'name' is required");

  # CGI parity: zone type is an enum (M/S/H/F/C/A); BackEnd would accept
  # any character, so the enum is enforced here like the CGI form does.
  my $raw_type = $input->{type} // 'M';
  my $type = uc(substr($raw_type, 0, 1));
  if ($type !~ /^[MSHFCA]$/) {
    SauronAPI::Exception->validation(
      "Invalid zone type '$type' (must be one of M, S, H, F, C, A)"
    );
  }

  # CGI only offers the reverse zone option for master zones.
  if ($input->{reverse} && $type ne 'M') {
    SauronAPI::Exception->validation(
      "Reverse zones must be master zones (type 'M')"
    );
  }

  # Reverse zones: accept a CIDR as the zone name and derive the arpa name.
  # NOTE: _copy_zone_fields copies 'name' from the input verbatim, so the
  # transform must happen after it.
  my $reverse = $input->{reverse} ? 1 : 0;
  my $effective_name = $zone_name;
  if ($reverse && Sauron::Util::is_cidr($effective_name) && $effective_name =~ /\/\d{1,3}$/) {
    $effective_name = Sauron::Util::cidr2arpa($effective_name);
  }

  my $existing_id = Sauron::BackEnd::get_zone_id($effective_name, $server_id);
  if ($existing_id > 0) {
    SauronAPI::Exception->conflict(
      "Zone '$zone_name' already exists on this server"
    );
  }

  my %rec = (
    server => $server_id,
    name   => $zone_name,
    type   => $type,
  );

  _copy_zone_fields(\%rec, $input, 0);  # skip_immutable=0 (allow all fields)

  if ($reverse) {
    $rec{reverse} = 't';
    $rec{name} = $effective_name;
    my $new_net = Sauron::Util::arpa2cidr($rec{name});
    if ($new_net eq '0.0.0.0/0' || $new_net eq '') {
      SauronAPI::Exception->validation("Invalid reverse zone name");
    }
    $rec{reversenet} = $new_net;
  }

  # RFC 9432 (CGI parity): catalog zones use TTL=0 and negative caching TTL=0
  if ($type eq 'C') {
    $rec{ttl} = 0;
    $rec{minimum} = 0;
  }

  for my $field (@ARRAY_FIELDS) {
    next unless exists $input->{$field};
    my $data = $FIELDS{$field}->encode_create($input->{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $zone_id = Sauron::BackEnd::add_zone(\%rec);
  if ($zone_id < 0) {
    SauronAPI::Exception->persistence(
      "Failed to create zone (code: $zone_id)"
    );
  }

  my %zone_data;
  _check(Sauron::BackEnd::get_zone($zone_id, \%zone_data),
         'Zone created but failed to retrieve data');

  return _build_zone_response($zone_id, \%zone_data);
}

sub zone_update {
  my ($zone_id, $input) = @_;

  # Reject immutable fields
  for my $field (qw(type reverse serial)) {
    if (exists $input->{$field}) {
      SauronAPI::Exception->validation(
        "Field '$field' is immutable after creation"
      );
    }
  }

  my %existing_zone;
  _check(Sauron::BackEnd::get_zone($zone_id, \%existing_zone),
         'Failed to fetch existing zone data');

  my %rec = (id => $zone_id);
  _copy_zone_fields(\%rec, $input, 1);  # skip_immutable=1 (reject type/reverse)

  # BackEnd::update_zone requires the current record type
  $rec{type} = $existing_zone{type};

  # Replace-all semantics for array fields
  for my $field (@ARRAY_FIELDS) {
    next unless exists $input->{$field};
    my $data = $FIELDS{$field}->encode_update($input->{$field}, $existing_zone{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $res = Sauron::BackEnd::update_zone(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence(
      "Failed to update zone (code: $res)"
    );
  }

  my %zone_data;
  _check(Sauron::BackEnd::get_zone($zone_id, \%zone_data),
         'Zone updated but failed to retrieve data');

  return _build_zone_response($zone_id, \%zone_data);
}

sub zone_delete {
  my ($zone_id) = @_;

  my $res = Sauron::BackEnd::delete_zone($zone_id);
  if ($res < 0) {
    SauronAPI::Exception->persistence(
      "Failed to delete zone (code: $res)"
    );
  }
  return;
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

sub _check {
  my ($rc, $err) = @_;
  return if $rc == 0;
  SauronAPI::Exception->persistence($err);
}

# db_query returns -1 on error instead of dying; a failed query must not
# silently become an empty result set.
sub _dbq {
  my ($sql, @bind) = @_;
  my @rows;
  my $rc = Sauron::DB::db_query($sql, \@rows, @bind);
  if ($rc < 0) {
    SauronAPI::Exception->persistence("Database query failed");
  }
  return \@rows;
}

# Copy scalar fields from input to %rec for creation/update.
# Skips immutable fields for updates.
sub _copy_zone_fields {
  my ($rec, $json, $skip_immutable) = @_;

  for my $field (@COPY_FIELDS) {
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
    dummy          => ($zone_data->{dummy} eq 't' ? JSON::PP::true : JSON::PP::false),
    flags          => $zone_data->{flags},
    rdate          => $zone_data->{rdate},
    cdate          => $zone_data->{cdate},
    cuser          => $zone_data->{cuser},
    mdate          => $zone_data->{mdate},
    muser          => $zone_data->{muser},
  };

  # Copy writable fields from ZoneFields
  for my $field (@COPY_FIELDS) {
    next if $field eq 'class';
    $response->{$field} = $zone_data->{$field}
      if exists $zone_data->{$field} && defined $zone_data->{$field};
  }

  # Boolean fields (BackEnd stores as 't'/'f')
  $response->{active}  = ($zone_data->{active} eq 't' ? JSON::PP::true : JSON::PP::false) if defined $zone_data->{active};
  $response->{reverse} = ($zone_data->{reverse} eq 't' ? JSON::PP::true : JSON::PP::false) if defined $zone_data->{reverse};

  # String fields with char codes
  $response->{type} = $zone_data->{type} if exists $zone_data->{type};
  $response->{class} = $zone_data->{class} if exists $zone_data->{class};

  # Copy array fields
  for my $field (@ARRAY_FIELDS) {
    if (ref $zone_data->{$field} eq 'ARRAY' && @{$zone_data->{$field}} > 1) {
      $response->{$field} = $FIELDS{$field}->decode($zone_data->{$field});
    }
  }

  return $response;
}

1;
