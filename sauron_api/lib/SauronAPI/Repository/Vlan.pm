package SauronAPI::Repository::Vlan;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(vlan_list vlan_find vlan_create vlan_update vlan_delete);

use Scalar::Util ();
use Sauron::BackEnd ();
use Sauron::DB      ();
use SauronAPI::Codecs     qw(value);
use SauronAPI::Exception  ();
use SauronAPI::ListQuery  qw(compile_filters parse_sort sort_sql sort_echo list_metadata set_total);
use SauronAPI::Repository qw(dbq check_rc with_statement_timeout LIST_STATEMENT_TIMEOUT_MS);
use JSON::PP ();

# ---------------------------------------------------------------------------
# Entry arrays. Wire and BackEnd keys are both dhcp_l/dhcp_l6; the entry
# tables need the numeric type (6 = IPv4, 16 = IPv6).
# ---------------------------------------------------------------------------

my @ARRAY_FIELDS = (
  { key => 'dhcp_l',  type => 6,  codec => value(key => 'dhcp', label => 'DHCP') },
  { key => 'dhcp_l6', type => 16, codec => value(key => 'dhcp', label => 'DHCP') },
);

# ---------------------------------------------------------------------------
# List filters and sorting (ADR 0009)
# ---------------------------------------------------------------------------

my %FILTER_SPEC = (
  name        => { kind => 'regex', col => 'name' },
  vlanno      => { kind => 'int',   col => 'vlanno' },
  description => { kind => 'regex', col => 'description' },
  comment     => { kind => 'regex', col => 'comment' },
);

my %SORT_COLUMN = (
  name        => 'name',
  vlanno      => 'vlanno',
  description => 'description',
  comment     => 'comment',
);

# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------

sub vlan_list {
  my ($server_id, %opts) = @_;

  my $page     = $opts{page}     // 1;
  my $per_page = $opts{per_page} // 50;

  my $sort = parse_sort($opts{sort}, \%SORT_COLUMN, default => 'name', tiebreak => 'id');
  my $filters = compile_filters($opts{params} // {}, \%FILTER_SPEC);
  my $meta = list_metadata($page, $per_page, sort_echo($sort), $filters->{echo});

  return ([], $meta) if $filters->{empty};

  my @bind = ($server_id);
  my $where = ' WHERE server=? ';
  if ($filters->{where}) {
    $where .= " AND $filters->{where} ";
    push @bind, @{$filters->{bind}};
  }

  my ($rows, $count_rows);
  with_statement_timeout(LIST_STATEMENT_TIMEOUT_MS, sub {
    $rows = dbq(
      "SELECT id,name,vlanno,description,comment FROM vlans $where "
      . sort_sql($sort) . ' LIMIT ? OFFSET ?',
      @bind, $per_page, ($page - 1) * $per_page
    );
    $count_rows = dbq("SELECT COUNT(*) FROM vlans $where", @bind);
  });
  set_total($meta, $count_rows->[0][0] // 0);

  my $vlans = [ map { _build_summary($server_id, $_) } @$rows ];
  return ($vlans, $meta);
}

# ---------------------------------------------------------------------------
# Single record
# ---------------------------------------------------------------------------

sub vlan_find {
  my ($server_id, $vlan_id) = @_;

  my %data;
  check_rc(Sauron::BackEnd::get_vlan($vlan_id, \%data),
         'Failed to retrieve VLAN data');

  return _build_vlan_response($server_id, $vlan_id, \%data);
}

sub vlan_create {
  my ($server_id, $input) = @_;

  my $name = _require_name($input->{name});
  _validate_vlanno($input->{vlanno}) if exists $input->{vlanno};
  _validate_entries($input);
  _assert_unique_name($server_id, $name, undef);

  # Encode the entry arrays first; they are inserted separately below because
  # BackEnd::add_vlan drops the entry comments (issue #45).
  my %arrays;
  for my $field (@ARRAY_FIELDS) {
    next unless exists $input->{$field->{key}};
    my $data = $field->{codec}->encode_create($input->{$field->{key}});
    $arrays{$field->{key}} = $data if ref $data eq 'ARRAY';
  }

  my %rec = (
    server      => $server_id,
    name        => $name,
    vlanno      => exists $input->{vlanno} ? $input->{vlanno} : undef,
    description => $input->{description},
    comment     => $input->{comment},
  );

  SauronAPI::Exception->persistence('Failed to start transaction')
    unless Sauron::DB::db_begin();

  my $vlan_id;
  my $ok = eval {
    # add_vlan sets cdate/cuser and returns the new id; run it inside our
    # transaction so the entry inserts below are atomic with the row.
    Sauron::DB::db_ignore_begin_and_commit(1);
    my $res = eval { Sauron::BackEnd::add_vlan(\%rec) };
    my $err = $@;
    Sauron::DB::db_ignore_begin_and_commit(0);
    die $err if $err;
    die "add_vlan failed (code: $res)" if $res < 0;
    $vlan_id = $res;

    for my $field (@ARRAY_FIELDS) {
      next unless exists $arrays{$field->{key}};
      $rec{$field->{key}} = $arrays{$field->{key}};
      my $r = Sauron::BackEnd::add_array_field(
        'dhcp_entries', 'dhcp,comment', $field->{key}, \%rec,
        'type,ref', $field->{type} . ",$vlan_id");
      die "add_array_field failed (code: $r)" if $r < 0;
    }

    1;
  };
  my $err = $@;

  if (!$ok) {
    Sauron::DB::db_rollback();
    die $err if Scalar::Util::blessed($err) && $err->isa('SauronAPI::Exception');
    SauronAPI::Exception->persistence("Failed to create VLAN ($err)");
  }
  SauronAPI::Exception->persistence('Failed to commit VLAN creation')
    unless Sauron::DB::db_commit();

  my %data;
  check_rc(Sauron::BackEnd::get_vlan($vlan_id, \%data),
         'VLAN created but failed to retrieve data');

  return _build_vlan_response($server_id, $vlan_id, \%data);
}

sub vlan_update {
  my ($server_id, $vlan_id, $input) = @_;

  my %existing;
  check_rc(Sauron::BackEnd::get_vlan($vlan_id, \%existing),
         'Failed to retrieve existing VLAN data');

  _validate_entries($input);

  my %rec = (id => $vlan_id);

  if (exists $input->{name}) {
    my $name = _require_name($input->{name});
    _assert_unique_name($server_id, $name, $vlan_id);
    $rec{name} = $name;
  }
  if (exists $input->{vlanno}) {
    _validate_vlanno($input->{vlanno});
    $rec{vlanno} = $input->{vlanno};
  }
  if (exists $input->{description}) { $rec{description} = $input->{description}; }
  if (exists $input->{comment})     { $rec{comment}     = $input->{comment}; }

  # Replace-all semantics for entry arrays.
  for my $field (@ARRAY_FIELDS) {
    next unless exists $input->{$field->{key}};
    my $data = $field->{codec}->encode_update(
      $input->{$field->{key}}, $existing{$field->{key}});
    $rec{$field->{key}} = $data if ref $data eq 'ARRAY';
  }

  my $res = Sauron::BackEnd::update_vlan(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence("Failed to update VLAN (code: $res)");
  }

  my %data;
  check_rc(Sauron::BackEnd::get_vlan($vlan_id, \%data),
         'VLAN updated but failed to retrieve data');

  return _build_vlan_response($server_id, $vlan_id, \%data);
}

# Corrected delete (ADR 0009): remove the VLAN's IPv4 *and* IPv6 DHCP entries,
# delete the row, and detach references — networks (nets.vlan) and VMPS
# fallbacks. BackEnd::delete_vlan leaves type=16 rows and a dangling
# vmps.fallback (issue #44).
sub vlan_delete {
  my ($vlan_id) = @_;

  SauronAPI::Exception->persistence('Failed to start transaction')
    unless Sauron::DB::db_begin();

  my $ok = eval {
    dbq('DELETE FROM dhcp_entries WHERE ref=? AND type IN (6,16)', $vlan_id);
    dbq('DELETE FROM vlans WHERE id=?', $vlan_id);
    dbq('UPDATE nets SET vlan=-1 WHERE vlan=?', $vlan_id);
    dbq('UPDATE vmps SET fallback=-1 WHERE fallback=?', $vlan_id);
    1;
  };
  my $err = $@;

  if (!$ok) {
    Sauron::DB::db_rollback();
    die $err if Scalar::Util::blessed($err) && $err->isa('SauronAPI::Exception');
    SauronAPI::Exception->persistence('Failed to delete VLAN');
  }
  SauronAPI::Exception->persistence('Failed to commit VLAN deletion')
    unless Sauron::DB::db_commit();

  return;
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

sub _require_name {
  my ($name) = @_;
  SauronAPI::Exception->validation("'name' is required")
    unless defined $name && length $name;
  SauronAPI::Exception->validation(
    "'name' must match [A-Za-z0-9_.-]+"
  ) unless $name =~ /^[A-Za-z0-9_.-]+$/;
  return $name;
}

sub _validate_vlanno {
  my ($v) = @_;
  return unless defined $v;
  SauronAPI::Exception->validation("'vlanno' must be a non-negative integer")
    unless $v =~ /^\d+$/;
}

# Array entries require a non-empty DHCP value (form parity: empty=>[0,1]).
sub _validate_entries {
  my ($input) = @_;
  for my $key (qw(dhcp_l dhcp_l6)) {
    next unless exists $input->{$key};
    my $rows = $input->{$key};
    SauronAPI::Exception->validation("'$key' must be an array")
      unless ref $rows eq 'ARRAY';
    for my $row (@$rows) {
      my $v = ref $row eq 'HASH' ? $row->{dhcp} : undef;
      SauronAPI::Exception->validation("'$key' entries must have a non-empty 'dhcp'")
        unless defined $v && $v =~ /\S/;
    }
  }
}

sub _assert_unique_name {
  my ($server_id, $name, $self_id) = @_;
  my $existing = Sauron::BackEnd::get_vlan_by_name($server_id, $name);
  return unless $existing > 0;
  return if defined $self_id && $existing == $self_id;
  SauronAPI::Exception->conflict("VLAN '$name' already exists on this server");
}

sub _build_summary {
  my ($server_id, $row) = @_;
  my ($id, $name, $vlanno, $description, $comment) = @$row;

  return {
    id          => $id,
    server_id   => $server_id,
    name        => $name,
    vlanno      => $vlanno,
    description => $description,
    comment     => $comment,
  };
}

sub _build_vlan_response {
  my ($server_id, $vlan_id, $data) = @_;

  my $response = {
    id          => $vlan_id,
    server_id   => $server_id,
    name        => $data->{name},
    vlanno      => $data->{vlanno},
    description => $data->{description},
    comment     => $data->{comment},
    cdate       => $data->{cdate},
    cuser       => $data->{cuser},
    mdate       => $data->{mdate},
    muser       => $data->{muser},
  };

  for my $field (@ARRAY_FIELDS) {
    $response->{$field->{key}} = $field->{codec}->decode($data->{$field->{key}});
  }

  return $response;
}

1;
