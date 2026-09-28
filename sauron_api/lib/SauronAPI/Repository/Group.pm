package SauronAPI::Repository::Group;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  group_list group_find group_create group_update group_delete
  assignable_groups group_type_code group_type_slug
);

use Scalar::Util ();
use Sauron::BackEnd ();
use SauronAPI::Codecs     qw(value);
use SauronAPI::Exception  ();
use SauronAPI::ListQuery  qw(compile_filters parse_sort sort_sql sort_echo list_metadata set_total);
use SauronAPI::Repository qw(dbq check_rc with_statement_timeout LIST_STATEMENT_TIMEOUT_MS);
use JSON::PP ();

# ---------------------------------------------------------------------------
# Group type: wire slug <-> DB code (ADR 0008, mirrors Host type mapping).
# ---------------------------------------------------------------------------

my %TYPE_CODE = (
  normal            => 1,
  dynamic_pool      => 2,
  dhcp_class        => 3,
  custom_dhcp_class => 103,
);
my %TYPE_SLUG = reverse %TYPE_CODE;

# Types a group may be assigned as, by slot (legacy BackEnd::get_group_list
# rule, CGIutil.pm:1356-1360): a DHCP class only works as a subgroup.
my %ASSIGNABLE_TYPES = (
  base     => [1, 2],       # Normal, Dynamic Address Pool
  subgroup => [1, 2, 3],    # + DHCP class
);

sub group_type_code {
  my ($slug) = @_;
  SauronAPI::Exception->validation(
    "Invalid group type '" . (defined $slug ? $slug : 'undef') . "'"
  ) unless defined $slug && exists $TYPE_CODE{$slug};
  return $TYPE_CODE{$slug};
}

sub group_type_slug {
  my ($code) = @_;
  return $TYPE_SLUG{$code} // $code;
}

# ---------------------------------------------------------------------------
# Field tables. Wire names are the Host-style dhcp_l/dhcp_l6/printer_l; the
# BackEnd record keys are dhcp/dhcp6/printer (see BackEnd add_group/get_group).
# ---------------------------------------------------------------------------

my @ARRAY_FIELDS = (
  { wire => 'dhcp_l',    backend => 'dhcp',    codec => value(key => 'dhcp',    label => 'DHCP') },
  { wire => 'dhcp_l6',   backend => 'dhcp6',   codec => value(key => 'dhcp',    label => 'DHCP') },
  { wire => 'printer_l', backend => 'printer', codec => value(key => 'printer', label => 'PRINTER') },
);

# ---------------------------------------------------------------------------
# List filters and sorting (ADR 0007)
# ---------------------------------------------------------------------------

my %FILTER_SPEC = (
  name    => { kind => 'regex',  col => 'name' },
  type    => { kind => 'custom', code => sub {
      my $code = group_type_code($_[0]);
      return { clauses => ['type = ?'], bind => [$code] };
    } },
  comment => { kind => 'regex',  col => 'comment' },
  vmps    => { kind => 'int',    col => 'vmps' },
);

my %SORT_COLUMN = (
  name   => 'name',
  type   => 'type',
  alevel => 'alevel',
);

# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------

sub group_list {
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
      "SELECT id,name,type,alevel,vmps,comment FROM groups $where "
      . sort_sql($sort) . ' LIMIT ? OFFSET ?',
      @bind, $per_page, ($page - 1) * $per_page
    );
    $count_rows = dbq("SELECT COUNT(*) FROM groups $where", @bind);
  });
  set_total($meta, $count_rows->[0][0] // 0);

  my $groups = [ map { _build_summary($server_id, $_) } @$rows ];
  return ($groups, $meta);
}

# ---------------------------------------------------------------------------
# Single record
# ---------------------------------------------------------------------------

sub group_find {
  my ($server_id, $group_id) = @_;

  my %group_data;
  check_rc(Sauron::BackEnd::get_group($group_id, \%group_data),
         'Failed to retrieve group data');

  return _build_group_response($server_id, $group_id, \%group_data);
}

sub group_create {
  my ($server_id, $input) = @_;

  my $name = _require_name($input->{name});
  my $type = exists $input->{type} ? group_type_code($input->{type}) : 1;

  _assert_unique_name($server_id, $name, undef);
  _validate_alevel($input->{alevel}) if exists $input->{alevel};
  _validate_vmps($server_id, $input->{vmps}) if exists $input->{vmps};
  if (exists $input->{printer_l}) {
    SauronAPI::Exception->validation(
      "Field 'printer_l' is only valid for 'normal' groups"
    ) unless $type == 1;
  }

  my %rec = (
    server  => $server_id,
    name    => $name,
    type    => $type,
    alevel  => exists $input->{alevel} ? $input->{alevel} : 0,
    vmps    => _vmps_code($input->{vmps}),
    comment => $input->{comment},
  );

  for my $field (@ARRAY_FIELDS) {
    next unless exists $input->{$field->{wire}};
    my $data = $field->{codec}->encode_create($input->{$field->{wire}});
    $rec{$field->{backend}} = $data if ref $data eq 'ARRAY';
  }

  my $group_id = Sauron::BackEnd::add_group(\%rec);
  if ($group_id < 0) {
    SauronAPI::Exception->persistence("Failed to create group (code: $group_id)");
  }

  my %group_data;
  check_rc(Sauron::BackEnd::get_group($group_id, \%group_data),
         'Group created but failed to retrieve data');

  return _build_group_response($server_id, $group_id, \%group_data);
}

sub group_update {
  my ($server_id, $group_id, $input) = @_;

  my %existing;
  check_rc(Sauron::BackEnd::get_group($group_id, \%existing),
         'Failed to retrieve existing group data');

  my %rec = (id => $group_id);

  if (exists $input->{name}) {
    my $name = _require_name($input->{name});
    _assert_unique_name($server_id, $name, $group_id);
    $rec{name} = $name;
  }
  if (exists $input->{type}) {
    $rec{type} = group_type_code($input->{type});
  }
  if (exists $input->{alevel}) {
    _validate_alevel($input->{alevel});
    $rec{alevel} = $input->{alevel};
  }
  if (exists $input->{vmps}) {
    _validate_vmps($server_id, $input->{vmps});
    $rec{vmps} = _vmps_code($input->{vmps});
  }
  if (exists $input->{comment}) {
    $rec{comment} = $input->{comment};
  }

  my $effective_type = exists $rec{type} ? $rec{type} : $existing{type};
  if (exists $input->{printer_l} && $effective_type != 1) {
    SauronAPI::Exception->validation(
      "Field 'printer_l' is only valid for 'normal' groups"
    );
  }

  # Replace-all semantics for array fields.
  for my $field (@ARRAY_FIELDS) {
    next unless exists $input->{$field->{wire}};
    my $data = $field->{codec}->encode_update(
      $input->{$field->{wire}}, $existing{$field->{backend}});
    $rec{$field->{backend}} = $data if ref $data eq 'ARRAY';
  }

  my $res = Sauron::BackEnd::update_group(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence("Failed to update group (code: $res)");
  }

  my %group_data;
  check_rc(Sauron::BackEnd::get_group($group_id, \%group_data),
         'Group updated but failed to retrieve data');

  return _build_group_response($server_id, $group_id, \%group_data);
}

# Delete a group, first detaching or reassigning its member hosts.
# BackEnd::delete_group only removes the group row and its dhcp/printer
# entries; hosts.grp and group_entries are left dangling (no FK), so the
# legacy CGI repairs them itself (Sauron/CGI/Groups.pm:189-260). This mirrors
# that transaction: move members, drop subgroup rows, de-duplicate, delete.
sub group_delete {
  my ($server_id, $group_id, %opts) = @_;
  my $reassign_to = $opts{reassign_to};

  my $new_id = -1;
  if (defined $reassign_to && length $reassign_to) {
    $new_id = Sauron::BackEnd::get_group_by_name($server_id, $reassign_to);
    SauronAPI::Exception->not_found("Group '$reassign_to' not found")
      unless $new_id > 0;
    SauronAPI::Exception->validation(
      'Cannot reassign hosts to the group being deleted'
    ) if $new_id == $group_id;
  }

  SauronAPI::Exception->persistence('Failed to start transaction')
    unless Sauron::DB::db_begin();

  my $ok = eval {
    dbq('UPDATE hosts SET grp=? WHERE grp=?', $new_id, $group_id);

    if ($new_id > 0) {
      dbq('UPDATE group_entries SET grp=? WHERE grp=?', $new_id, $group_id);
    } else {
      dbq('DELETE FROM group_entries WHERE grp=? OR grp=-1', $group_id);
    }

    # Drop duplicate (host, grp) rows.
    dbq(
      'DELETE FROM group_entries WHERE id IN (SELECT id FROM '
      . '(SELECT id, ROW_NUMBER() OVER (PARTITION BY host, grp ORDER BY id) AS rnum '
      . 'FROM group_entries) t WHERE t.rnum > 1)'
    );

    # Drop subgroup rows that merely duplicate the host's base group.
    dbq(
      'DELETE FROM group_entries WHERE id IN '
      . '(SELECT ge.id FROM group_entries ge, hosts h '
      . 'WHERE h.grp = ge.grp AND h.id = ge.host)'
    );

    # BackEnd::delete_group opens/commits its own transaction; suppress that
    # so it participates in ours.
    Sauron::DB::db_ignore_begin_and_commit(1);
    my ($del, $del_err);
    {
      local $@;
      $del = eval { Sauron::BackEnd::delete_group($group_id) };
      $del_err = $@;
    }
    Sauron::DB::db_ignore_begin_and_commit(0);
    die $del_err if $del_err;
    die "delete group failed (code: $del)" if $del < 0;

    1;
  };
  my $err = $@;

  if (!$ok) {
    Sauron::DB::db_rollback();
    die $err if Scalar::Util::blessed($err) && $err->isa('SauronAPI::Exception');
    SauronAPI::Exception->persistence('Failed to delete group');
  }

  SauronAPI::Exception->persistence('Failed to commit group deletion')
    unless Sauron::DB::db_commit();

  return;
}

# ---------------------------------------------------------------------------
# Assignable groups (picker) — legacy BackEnd::get_group_list parity.
# ---------------------------------------------------------------------------

sub assignable_groups {
  my ($server_id, %opts) = @_;

  my $role = $opts{role} // 'base';
  my $types = $ASSIGNABLE_TYPES{$role}
    or SauronAPI::Exception->validation(
      "Invalid role '$role' (allowed: base, subgroup)");
  my $max_alevel = $opts{max_alevel};    # undef = no ceiling (superuser)

  my @bind = ($server_id, @$types);
  my $sql = 'SELECT id,name,type FROM groups WHERE server=? AND type IN ('
    . join(',', ('?') x @$types) . ')';
  if (defined $max_alevel) {
    $sql .= ' AND alevel <= ?';
    push @bind, $max_alevel;
  }
  $sql .= ' ORDER BY name';

  my $rows = dbq($sql, @bind);
  return [ map { +{
    id   => $_->[0],
    name => $_->[1],
    type => group_type_slug($_->[2]),
  } } @$rows ];
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

sub _require_name {
  my ($name) = @_;
  SauronAPI::Exception->validation("'name' is required")
    unless defined $name && length $name;
  SauronAPI::Exception->validation("'name' must not be blank")
    unless $name =~ /\S/;
  return $name;
}

sub _validate_alevel {
  my ($v) = @_;
  SauronAPI::Exception->validation("'alevel' must be a non-negative integer")
    unless defined $v && $v =~ /^\d+$/;
}

# TODO: VMPS picker endpoint needed — 'vmps' is writable here but the API has
# no VMPS listing yet, so a client cannot discover valid ids (ADR 0008).
sub _validate_vmps {
  my ($server_id, $v) = @_;
  return unless defined $v;
  SauronAPI::Exception->validation("'vmps' must be a positive integer")
    unless $v =~ /^\d+$/ && $v > 0;
  my $rows = dbq('SELECT id FROM vmps WHERE id=? AND server=?', $v, $server_id);
  SauronAPI::Exception->validation('Unknown VMPS domain for this server')
    unless @$rows;
}

# Wire null / absent -> BackEnd's -1 "none" sentinel.
sub _vmps_code {
  my ($v) = @_;
  return -1 unless defined $v;
  return $v;
}

sub _assert_unique_name {
  my ($server_id, $name, $self_id) = @_;
  my $existing = Sauron::BackEnd::get_group_by_name($server_id, $name);
  return unless $existing > 0;
  return if defined $self_id && $existing == $self_id;
  SauronAPI::Exception->conflict("Group '$name' already exists on this server");
}

sub _vmps_name {
  my ($vmps_id) = @_;
  return undef unless defined $vmps_id && $vmps_id > 0;
  my $rows = dbq('SELECT name FROM vmps WHERE id=?', $vmps_id);
  return @$rows ? $rows->[0][0] : undef;
}

sub _build_summary {
  my ($server_id, $row) = @_;
  my ($id, $name, $type, $alevel, $vmps, $comment) = @$row;

  return {
    id        => $id,
    server_id => $server_id,
    name      => $name,
    type      => group_type_slug($type),
    alevel    => $alevel // 0,
    comment   => $comment // '',
    vmps      => (defined $vmps && $vmps > 0) ? $vmps : undef,
  };
}

sub _build_group_response {
  my ($server_id, $group_id, $data) = @_;

  my $vmps = $data->{vmps} // -1;

  my $response = {
    id        => $group_id,
    server_id => $server_id,
    name      => $data->{name},
    type      => group_type_slug($data->{type}),
    alevel    => $data->{alevel} // 0,
    comment   => $data->{comment} // '',
    vmps      => $vmps > 0 ? $vmps : undef,
    vmps_name => _vmps_name($vmps),
    cdate     => $data->{cdate},
    cuser     => $data->{cuser},
    mdate     => $data->{mdate},
    muser     => $data->{muser},
  };

  for my $field (@ARRAY_FIELDS) {
    $response->{$field->{wire}} =
      $field->{codec}->decode($data->{$field->{backend}});
  }

  return $response;
}

1;
