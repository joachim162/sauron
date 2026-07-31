package SauronAPI::Repository::Server;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  server_list server_find server_create server_update server_delete
);

use Sauron::BackEnd ();
use SauronAPI::Codecs     qw(aml value forwarder);
use SauronAPI::Exception  ();
use SauronAPI::Repository qw(dbq check_rc);
use JSON::PP ();

# ---------------------------------------------------------------------------
# Field tables (moved from SauronAPI::Controller::Server)
# ---------------------------------------------------------------------------

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

my @ARRAY_FIELDS = qw(
  allow_transfer allow_query allow_recursion blackhole listen_on listen_on_v6
  allow_query_cache allow_notify forwarders
  dhcp_l dhcp txt logging custom_opts bind_globals dhcp6_l dhcp6
);

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

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

sub server_list {
  my $rows = dbq("SELECT id,name,comment FROM servers ORDER BY name");
  return [ map { +{ id => $_->[0], name => $_->[1], comment => $_->[2] // '' } } @$rows ];
}

sub server_find {
  my ($server_id) = @_;

  my %server_data;
  check_rc(Sauron::BackEnd::get_server($server_id, \%server_data),
         'Failed to retrieve server data');

  return _build_server_response($server_id, \%server_data);
}

sub server_create {
  my ($input) = @_;

  my $name = $input->{name}
    or SauronAPI::Exception->validation("'name' is required");

  my $existing_id = Sauron::BackEnd::get_server_id($name);
  if ($existing_id > 0) {
    SauronAPI::Exception->conflict("Server '$name' already exists");
  }

  my %rec = (name => $name);
  _copy_scalar_fields(\%rec, $input);

  for my $field (@ARRAY_FIELDS) {
    next unless exists $input->{$field};
    my $data = $FIELDS{$field}->encode_create($input->{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $server_id = Sauron::BackEnd::add_server(\%rec);
  if ($server_id < 0) {
    SauronAPI::Exception->persistence(
      "Failed to create server (code: $server_id)"
    );
  }

  my %server_data;
  check_rc(Sauron::BackEnd::get_server($server_id, \%server_data),
         'Server created but failed to retrieve data');

  return _build_server_response($server_id, \%server_data);
}

sub server_update {
  my ($server_id, $input) = @_;

  my %server_data;
  check_rc(Sauron::BackEnd::get_server($server_id, \%server_data),
         'Failed to retrieve server data');

  my %rec = (id => $server_id);
  _copy_scalar_fields(\%rec, $input);

  # Replace-all semantics for array fields
  for my $field (@ARRAY_FIELDS) {
    next unless exists $input->{$field};
    my $data = $FIELDS{$field}->encode_update($input->{$field}, $server_data{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $res = Sauron::BackEnd::update_server(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence(
      "Failed to update server (code: $res)"
    );
  }

  check_rc(Sauron::BackEnd::get_server($server_id, \%server_data),
         'Server updated but failed to retrieve data');

  return _build_server_response($server_id, \%server_data);
}

sub server_delete {
  my ($server_id) = @_;

  my $res = Sauron::BackEnd::delete_server($server_id);
  if ($res < 0) {
    SauronAPI::Exception->persistence(
      "Failed to delete server (code: $res)"
    );
  }
  return;
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Copy scalar fields, boolean fields, and decomposed flags from input to %rec.
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

1;
