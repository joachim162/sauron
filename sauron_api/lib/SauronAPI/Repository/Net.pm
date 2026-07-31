package SauronAPI::Repository::Net;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  net_list net_find net_create net_update net_delete net_id_for
);

use Sauron::BackEnd ();
use Sauron::Util   ();
use SauronAPI::Codecs     qw(value);
use SauronAPI::Exception  ();
use SauronAPI::Repository qw(dbq check_rc);
use JSON::PP ();

# ---------------------------------------------------------------------------
# Field tables (moved from SauronAPI::Controller::Net)
# ---------------------------------------------------------------------------

my @SCALAR_FIELDS = qw(
  netname name net vlan alevel comment
  range_start range_end ip_policy
  rp_mbox rp_txt
);

my @ARRAY_FIELDS = qw(dhcp_l);

my %FIELDS = (
  dhcp_l => value(key => 'dhcp', label => 'DHCP'),
);

# ---------------------------------------------------------------------------
# Name/CIDR resolution
# ---------------------------------------------------------------------------

sub net_id_for {
  my ($server_id, $param) = @_;

  my $net_id = Sauron::BackEnd::get_net_by_cidr($server_id, $param);
  return $net_id if $net_id > 0;

  my $rows = dbq("SELECT id FROM nets WHERE server=? AND netname=?",
                  $server_id, $param);
  return $rows->[0][0] if @$rows > 0 && $rows->[0][0] > 0;
  return -1;
}

# ---------------------------------------------------------------------------
# Lists (own SQL, bound params; BackEnd::get_net_list WHERE/UNION ported)
# ---------------------------------------------------------------------------

sub net_list {
  my ($server_id, %opts) = @_;

  my $rows = _list_rows($server_id, %opts);
  my $vlan_map = $opts{include_vlan_names} ? _vlan_map($server_id) : undef;
  my @nets = map { _build_net_list_response($_, $vlan_map) } @$rows;

  if ($opts{page} && $opts{per_page}) {
    my $total = _list_count($server_id, %opts);
    my $per_page = $opts{per_page};
    my $metadata = {
      pagination => {
        total       => $total,
        page        => $opts{page},
        per_page    => $per_page,
        total_pages => $per_page > 0 ? int(($total + $per_page - 1) / $per_page) : 0,
      },
      sort    => [],
      filters => [],
    };
    return (\@nets, $metadata);
  }
  return \@nets;
}

# Core SELECT/WHERE (plus free-block UNION) shared by row fetch and COUNT.
sub _list_query {
  my ($server_id, %opts) = @_;

  my @bind = ($server_id);
  my $where = " WHERE server=? ";
  $where .= " AND subnet=true " if $opts{subnets};
  if (defined $opts{alevel} && $opts{alevel} > 0) {
    $where .= " AND alevel <= ? ";
    push @bind, $opts{alevel};
  }

  my $sql =
    "SELECT net,id,name,netname,comment,no_dhcp,dummy,vlan,alevel,subnet " .
    "FROM nets" . $where;

  if ($opts{free}) {
    # Unallocated blocks as pseudo records (id=-1), one row per gap in each
    # top-level net (same union as BackEnd::get_net_list / CGI browse_nets).
    $sql .=
      " UNION SELECT unallocated_subnets(?,net) AS net,-1,'','','',true,false,-1,-1,true " .
      "FROM nets WHERE server=? AND subnet=false AND dummy=false ";
    push @bind, $server_id, $server_id;
  }

  return ($sql, @bind);
}

sub _list_rows {
  my ($server_id, %opts) = @_;

  my ($sql, @bind) = _list_query($server_id, %opts);
  $sql .= " ORDER BY net ";
  if ($opts{page} && $opts{per_page}) {
    $sql .= " LIMIT ? OFFSET ? ";
    push @bind, $opts{per_page}, ($opts{page} - 1) * $opts{per_page};
  }

  return dbq($sql, @bind);
}

sub _list_count {
  my ($server_id, %opts) = @_;

  my ($sql, @bind) = _list_query($server_id, %opts);
  my $rows = dbq("SELECT COUNT(*) FROM ($sql) q", @bind);
  return $rows->[0][0] // 0;
}

sub _vlan_map {
  my ($server_id) = @_;

  my $rows = dbq(
    "SELECT id,name FROM vlans WHERE server=? ORDER BY name",
    $server_id
  );
  my %map = map { $_->[0] => $_->[1] } @$rows;
  return \%map;
}

sub _build_net_list_response {
  my ($row, $vlan_map) = @_;

  my $dummy   = (defined $row->[6] && ($row->[6] eq 't' || $row->[6] eq '1'));
  my $no_dhcp = (defined $row->[5] && ($row->[5] eq 't' || $row->[5] eq '1'));
  my $subnet  = (defined $row->[9] && ($row->[9] eq 't' || $row->[9] eq '1'));
  my $unallocated = (defined $row->[1] && $row->[1] == -1);

  my $dhcp = ($dummy || $unallocated)
    ? undef : ($no_dhcp ? JSON::PP::false : JSON::PP::true);

  my $vlan_id = $row->[7] // -1;
  my $vlan_name = undef;
  if ($vlan_map && $vlan_id > 0) {
    $vlan_name = $vlan_map->{$vlan_id};
  }

  return {
    id        => $row->[1],
    net       => $row->[0],
    netname   => $row->[3],
    name      => $row->[2],
    subnet    => ($subnet ? JSON::PP::true : JSON::PP::false),
    dummy     => ($dummy  ? JSON::PP::true : JSON::PP::false),
    dhcp      => $dhcp,
    vlan      => $vlan_id,
    vlan_name => $vlan_name,
    alevel    => $row->[8] // 0,
  };
}

# ---------------------------------------------------------------------------
# Single record (BackEnd anti-corruption, VLAN enrichment from own SQL)
# ---------------------------------------------------------------------------

sub net_find {
  my ($net_id, %opts) = @_;

  my %net_data;
  check_rc(Sauron::BackEnd::get_net($net_id, \%net_data),
         'Failed to retrieve network data');

  my $vlan_map;
  if ($opts{include_vlan_names}) {
    $vlan_map = _vlan_map($opts{server_id} // $net_data{server});
  }

  return _build_net_response($net_id, \%net_data, $vlan_map);
}

sub net_create {
  my ($server_id, $input) = @_;

  my $netname = $input->{netname}
    or SauronAPI::Exception->validation("'netname' is required");

  my $net_cidr = $input->{net}
    or SauronAPI::Exception->validation("'net' (CIDR) is required");

  unless (Sauron::Util::is_cidr($net_cidr)) {
    SauronAPI::Exception->validation("'net' $net_cidr is not a valid CIDR");
  }

  my $existing_id = Sauron::BackEnd::get_net_by_cidr($server_id, $net_cidr);
  if ($existing_id > 0) {
    SauronAPI::Exception->conflict(
      "Network '$net_cidr' already exists on this server"
    );
  }

  my %rec = (
    server => $server_id,
    net    => $net_cidr,
  );
  _copy_scalar_fields(\%rec, $input);

  for my $field (@ARRAY_FIELDS) {
    next unless exists $input->{$field};
    my $data = $FIELDS{$field}->encode_create($input->{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $net_id = Sauron::BackEnd::add_net(\%rec);
  if ($net_id < 0) {
    SauronAPI::Exception->persistence(
      "Failed to create network (code: $net_id)"
    );
  }

  my %net_data;
  check_rc(Sauron::BackEnd::get_net($net_id, \%net_data),
         'Network created but failed to retrieve data');

  return _build_net_response($net_id, \%net_data, undef);
}

sub net_update {
  my ($net_id, $input) = @_;

  my %net_data;
  check_rc(Sauron::BackEnd::get_net($net_id, \%net_data),
         'Failed to retrieve existing network data');

  my %rec = (id => $net_id, net => $net_data{net});
  _copy_scalar_fields(\%rec, $input);

  for my $field (@ARRAY_FIELDS) {
    next unless exists $input->{$field};
    my $data = $FIELDS{$field}->encode_update($input->{$field}, $net_data{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $res = Sauron::BackEnd::update_net(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence(
      "Failed to update network (code: $res)"
    );
  }

  check_rc(Sauron::BackEnd::get_net($net_id, \%net_data),
         'Network updated but failed to retrieve data');

  return _build_net_response($net_id, \%net_data, undef);
}

sub net_delete {
  my ($net_id) = @_;

  my $res = Sauron::BackEnd::delete_net($net_id);
  if ($res < 0) {
    SauronAPI::Exception->persistence(
      "Failed to delete network (code: $res)"
    );
  }
  return;
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

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

  $response->{subnet} = ($net_data->{subnet} eq 't' ? JSON::PP::true : JSON::PP::false)
    if defined $net_data->{subnet};
  $response->{dummy} = ($net_data->{dummy} eq 't' ? JSON::PP::true : JSON::PP::false)
    if defined $net_data->{dummy};
  $response->{no_dhcp} = ($net_data->{no_dhcp} eq 't' ? JSON::PP::true : JSON::PP::false)
    if defined $net_data->{no_dhcp};
  $response->{private_flag} = ($net_data->{private_flag} ? JSON::PP::true : JSON::PP::false)
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

1;
