package SauronAPI::Repository::Template;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  mx_template_list mx_template_find mx_template_create mx_template_update mx_template_delete
  wks_template_list wks_template_find wks_template_create wks_template_update wks_template_delete
  printer_class_list printer_class_find printer_class_create printer_class_update printer_class_delete
  hinfo_template_list hinfo_template_find hinfo_template_create hinfo_template_update hinfo_template_delete
  assignable_mx_templates assignable_wks_templates
);

use Scalar::Util ();
use Sauron::BackEnd ();
use Sauron::DB      ();
use SauronAPI::Codecs     qw(mx wks printer);
use SauronAPI::Exception  ();
use SauronAPI::ListQuery  qw(compile_filters parse_sort sort_sql sort_echo list_metadata set_total);
use SauronAPI::Repository qw(dbq check_rc with_statement_timeout LIST_STATEMENT_TIMEOUT_MS);

# ---------------------------------------------------------------------------
# Per-kind configuration (ADR 0010)
# ---------------------------------------------------------------------------

my %KIND = (
  mx => {
    table       => 'mx_templates',
    scope_col   => 'zone',
    scope_field => 'zone_id',
    has_alevel  => 1,
    entry_key   => 'mx_l',
    codec       => mx(),
    host_col    => 'mx',
    get         => \&Sauron::BackEnd::get_mx_template,
    add         => \&Sauron::BackEnd::add_mx_template,
    upd         => \&Sauron::BackEnd::update_mx_template,
    del         => \&Sauron::BackEnd::delete_mx_template,
  },
  wks => {
    table       => 'wks_templates',
    scope_col   => 'server',
    scope_field => 'server_id',
    has_alevel  => 1,
    entry_key   => 'wks_l',
    codec       => wks(),
    host_col    => 'wks',
    get         => \&Sauron::BackEnd::get_wks_template,
    add         => \&Sauron::BackEnd::add_wks_template,
    upd         => \&Sauron::BackEnd::update_wks_template,
    del         => \&Sauron::BackEnd::delete_wks_template,
  },
  printer => {
    table       => 'printer_classes',
    scope_col   => undef,
    has_alevel  => 0,
    entry_key   => 'printer_l',
    codec       => printer(),
    get         => \&Sauron::BackEnd::get_printer_class,
    add         => \&Sauron::BackEnd::add_printer_class,
    upd         => \&Sauron::BackEnd::update_printer_class,
    del         => \&Sauron::BackEnd::delete_printer_class,
  },
  hinfo => {
    table      => 'hinfo_templates',
    scope_col  => undef,
    has_alevel => 0,
    entry_key  => undef,
    get        => \&Sauron::BackEnd::get_hinfo_template,
    add        => \&Sauron::BackEnd::add_hinfo_template,
    upd        => \&Sauron::BackEnd::update_hinfo_template,
    del        => \&Sauron::BackEnd::delete_hinfo_template,
  },
);

# List columns / filters / sorting per kind (ADR 0010).
my %LIST = (
  mx => {
    cols         => [qw(id name comment alevel cdate cuser mdate muser)],
    filter_spec  => { name => { kind => 'regex', col => 'name' },
                      comment => { kind => 'regex', col => 'comment' },
                      alevel => { kind => 'int', col => 'alevel' } },
    sort_column  => { name => 'name', comment => 'comment', alevel => 'alevel' },
    default_sort => ['name'],
  },
  wks => {
    cols         => [qw(id name comment alevel cdate cuser mdate muser)],
    filter_spec  => { name => { kind => 'regex', col => 'name' },
                      comment => { kind => 'regex', col => 'comment' },
                      alevel => { kind => 'int', col => 'alevel' } },
    sort_column  => { name => 'name', comment => 'comment', alevel => 'alevel' },
    default_sort => ['name'],
  },
  printer => {
    cols         => [qw(id name comment cdate cuser mdate muser)],
    filter_spec  => { name => { kind => 'regex', col => 'name' },
                      comment => { kind => 'regex', col => 'comment' } },
    sort_column  => { name => 'name', comment => 'comment' },
    default_sort => ['name'],
  },
  hinfo => {
    cols         => [qw(id hinfo type pri cdate cuser mdate muser)],
    filter_spec  => { hinfo => { kind => 'regex', col => 'hinfo' },
                      type  => { kind => 'custom', code => sub {
                          my $code = _hinfo_type_code($_[0]);
                          return { clauses => ['type = ?'], bind => [$code] };
                        } },
                      pri   => { kind => 'int', col => 'pri' } },
    sort_column  => { hinfo => 'hinfo', type => 'type', pri => 'pri' },
    default_sort => [qw(type pri hinfo)],
  },
);

# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------

sub _template_list {
  my ($kind, $scope_id, %opts) = @_;
  my $cfg  = $KIND{$kind};
  my $list = $LIST{$kind};

  my $page     = $opts{page}     // 1;
  my $per_page = $opts{per_page} // 50;

  my $sort    = parse_sort($opts{sort}, $list->{sort_column},
                  default => $list->{default_sort}, tiebreak => 'id');
  my $filters = compile_filters($opts{params} // {}, $list->{filter_spec});
  my $meta    = list_metadata($page, $per_page, sort_echo($sort), $filters->{echo});

  return ([], $meta) if $filters->{empty};

  my (@bind, @where);
  if ($cfg->{scope_col}) {
    push @where, "$cfg->{scope_col}=?";
    push @bind, $scope_id;
  }
  if ($filters->{where}) {
    push @where, $filters->{where};
    push @bind, @{$filters->{bind}};
  }
  my $where = @where ? ' WHERE ' . join(' AND ', @where) : '';

  my ($rows, $count_rows);
  with_statement_timeout(LIST_STATEMENT_TIMEOUT_MS, sub {
    $rows = dbq(
      'SELECT ' . join(',', @{$list->{cols}}) . " FROM $cfg->{table} $where "
      . sort_sql($sort) . ' LIMIT ? OFFSET ?',
      @bind, $per_page, ($page - 1) * $per_page
    );
    $count_rows = dbq("SELECT COUNT(*) FROM $cfg->{table} $where", @bind);
  });
  set_total($meta, $count_rows->[0][0] // 0);

  my $data = [ map { _summary_from_row($kind, $_, $scope_id) } @$rows ];
  return ($data, $meta);
}

sub mx_template_list    { my ($zone_id, %opts)   = @_; return _template_list('mx',      $zone_id,   %opts) }
sub wks_template_list   { my ($server_id, %opts) = @_; return _template_list('wks',     $server_id, %opts) }
sub printer_class_list  { my (%opts)             = @_; return _template_list('printer', undef,      %opts) }
sub hinfo_template_list { my (%opts)             = @_; return _template_list('hinfo',   undef,      %opts) }

# ---------------------------------------------------------------------------
# Find
# ---------------------------------------------------------------------------

sub _template_find {
  my ($kind, $id, $scope_id) = @_;
  my $cfg = $KIND{$kind};

  my %data;
  return undef if $cfg->{get}->($id, \%data) != 0;

  if ($cfg->{scope_col}) {
    my $rows = dbq("SELECT $cfg->{scope_col} FROM $cfg->{table} WHERE id=?", $id);
    return undef unless @$rows && $rows->[0][0] == $scope_id;
  }

  return _template_detail($kind, $id, $scope_id, \%data);
}

sub mx_template_find    { my ($zone_id, $id)   = @_; return _find_or_die('mx',      $id, $zone_id) }
sub wks_template_find   { my ($server_id, $id) = @_; return _find_or_die('wks',     $id, $server_id) }
sub printer_class_find  { my ($id)             = @_; return _find_or_die('printer', $id, undef) }
sub hinfo_template_find { my ($id)             = @_; return _find_or_die('hinfo',   $id, undef) }

sub _find_or_die {
  my ($kind, $id, $scope_id) = @_;
  my $found = _template_find($kind, $id, $scope_id);
  SauronAPI::Exception->not_found("Template $id not found") unless $found;
  return $found;
}

# ---------------------------------------------------------------------------
# Create / update
# ---------------------------------------------------------------------------

sub _template_create {
  my ($kind, $scope_id, $input) = @_;
  my $cfg = $KIND{$kind};

  my %rec;
  if ($kind eq 'hinfo') {
    $rec{hinfo} = _require_hinfo($input->{hinfo});
    $rec{type}  = _hinfo_type_code(exists $input->{type} ? $input->{type} : 'hardware');
    $rec{pri}   = exists $input->{pri} ? $input->{pri} : 100;
    _validate_int_nonneg('pri', $rec{pri});
  } else {
    $rec{name}    = $kind eq 'printer' ? _require_printer_name($input->{name})
                                       : _require_name($input->{name});
    $rec{comment} = $input->{comment};
    if ($cfg->{has_alevel}) {
      $rec{alevel} = exists $input->{alevel} ? $input->{alevel} : 0;
      _validate_int_nonneg('alevel', $rec{alevel});
    }
    $rec{ $cfg->{scope_col} } = $scope_id if $cfg->{scope_col};
    if ($cfg->{entry_key}) {
      _validate_entries($kind, $input);
      $rec{ $cfg->{entry_key} } =
        $cfg->{codec}->encode_create($input->{ $cfg->{entry_key} } // []);
    }
  }

  my $id = $cfg->{add}->(\%rec);
  SauronAPI::Exception->persistence("Failed to create template (code: $id)")
    if $id < 0;
  return $id;
}

sub _template_update {
  my ($kind, $id, $scope_id, $input) = @_;
  my $cfg = $KIND{$kind};

  my %existing;
  check_rc($cfg->{get}->($id, \%existing), 'Failed to retrieve template');

  my %rec = (id => $id);
  if ($kind eq 'hinfo') {
    $rec{hinfo} = _require_hinfo($input->{hinfo}) if exists $input->{hinfo};
    $rec{type}  = _hinfo_type_code($input->{type}) if exists $input->{type};
    if (exists $input->{pri}) {
      _validate_int_nonneg('pri', $input->{pri});
      $rec{pri} = $input->{pri};
    }
  } else {
    if (exists $input->{name}) {
      $rec{name} = $kind eq 'printer' ? _require_printer_name($input->{name})
                                      : _require_name($input->{name});
    }
    $rec{comment} = $input->{comment} if exists $input->{comment};
    if ($cfg->{has_alevel} && exists $input->{alevel}) {
      _validate_int_nonneg('alevel', $input->{alevel});
      $rec{alevel} = $input->{alevel};
    }
    if ($cfg->{entry_key} && exists $input->{ $cfg->{entry_key} }) {
      _validate_entries($kind, $input);
      $rec{ $cfg->{entry_key} } = $cfg->{codec}->encode_update(
        $input->{ $cfg->{entry_key} }, $existing{ $cfg->{entry_key} });
    }
  }

  my $rc = $cfg->{upd}->(\%rec);
  SauronAPI::Exception->persistence("Failed to update template (code: $rc)")
    if $rc < 0;
  return;
}

sub mx_template_create    { my ($zone_id, $input)   = @_; return _template_create('mx',      $zone_id,   $input) }
sub wks_template_create   { my ($server_id, $input) = @_; return _template_create('wks',     $server_id, $input) }
sub printer_class_create  { my ($input)             = @_; return _template_create('printer', undef,      $input) }
sub hinfo_template_create { my ($input)             = @_; return _template_create('hinfo',   undef,      $input) }

sub mx_template_update    { my ($zone_id, $id, $input)   = @_; return _template_update('mx',      $id, $zone_id,   $input) }
sub wks_template_update   { my ($server_id, $id, $input) = @_; return _template_update('wks',     $id, $server_id, $input) }
sub printer_class_update  { my ($id, $input)             = @_; return _template_update('printer', $id, undef,      $input) }
sub hinfo_template_update { my ($id, $input)             = @_; return _template_update('hinfo',   $id, undef,      $input) }

# ---------------------------------------------------------------------------
# Delete (MX/WKS: optional reassign-to, mirroring group_delete)
# ---------------------------------------------------------------------------

sub _template_delete {
  my ($kind, $id, $scope_id, $reassign_to) = @_;
  my $cfg = $KIND{$kind};

  if (defined $reassign_to && $reassign_to ne '' && !$cfg->{host_col}) {
    SauronAPI::Exception->validation(
      "'reassign_to' is only supported for MX and WKS templates");
  }

  my $new_id = -1;
  if ($cfg->{host_col} && defined $reassign_to && $reassign_to ne '') {
    SauronAPI::Exception->validation("'reassign_to' must be a positive integer")
      unless $reassign_to =~ /^\d+$/ && $reassign_to > 0;
    SauronAPI::Exception->validation('Cannot reassign to the template being deleted')
      if $reassign_to == $id;

    my $rows = dbq("SELECT $cfg->{scope_col} FROM $cfg->{table} WHERE id=?",
                   $reassign_to);
    SauronAPI::Exception->not_found("Reassign target '$reassign_to' not found")
      unless @$rows;
    SauronAPI::Exception->validation('Reassign target is in a different scope')
      unless $rows->[0][0] == $scope_id;
    $new_id = $reassign_to + 0;
  }

  SauronAPI::Exception->persistence('Failed to start transaction')
    unless Sauron::DB::db_begin();

  my $ok = eval {
    if ($cfg->{host_col}) {
      dbq("UPDATE hosts SET $cfg->{host_col}=? WHERE $cfg->{host_col}=?",
          $new_id, $id);
    }

    # BackEnd delete opens/commits its own transaction; suppress that so it
    # participates in ours (group_delete pattern).
    Sauron::DB::db_ignore_begin_and_commit(1);
    my ($rc, $err);
    {
      local $@;
      $rc = eval { $cfg->{del}->($id) };
      $err = $@;
    }
    Sauron::DB::db_ignore_begin_and_commit(0);
    die $err if $err;
    die "delete failed (code: $rc)" if defined $rc && $rc < 0;
    1;
  };
  my $err = $@;

  if (!$ok) {
    Sauron::DB::db_rollback();
    die $err if Scalar::Util::blessed($err) && $err->isa('SauronAPI::Exception');
    SauronAPI::Exception->persistence('Failed to delete template');
  }
  SauronAPI::Exception->persistence('Failed to commit deletion')
    unless Sauron::DB::db_commit();

  return;
}

sub mx_template_delete    { my ($zone_id, $id, $reassign_to)   = @_; return _template_delete('mx',      $id, $zone_id,   $reassign_to) }
sub wks_template_delete   { my ($server_id, $id, $reassign_to) = @_; return _template_delete('wks',     $id, $server_id, $reassign_to) }
sub printer_class_delete  { my ($id)                            = @_; return _template_delete('printer', $id, undef,      undef) }
sub hinfo_template_delete { my ($id)                            = @_; return _template_delete('hinfo',   $id, undef,      undef) }

# ---------------------------------------------------------------------------
# Assignable pickers (bare arrays, alevel ceiling)
# ---------------------------------------------------------------------------

sub assignable_mx_templates {
  my ($zone_id, $max_alevel) = @_;
  my ($where, @bind) = ('zone=?', $zone_id);
  if (defined $max_alevel) { $where .= ' AND alevel <= ?'; push @bind, $max_alevel; }
  my $rows = dbq("SELECT id,name,alevel FROM mx_templates WHERE $where ORDER BY name", @bind);
  return [ map { { id => $_->[0] + 0, name => $_->[1], alevel => $_->[2] + 0 } } @$rows ];
}

sub assignable_wks_templates {
  my ($server_id, $max_alevel) = @_;
  my ($where, @bind) = ('server=?', $server_id);
  if (defined $max_alevel) { $where .= ' AND alevel <= ?'; push @bind, $max_alevel; }
  my $rows = dbq("SELECT id,name,alevel FROM wks_templates WHERE $where ORDER BY name", @bind);
  return [ map { { id => $_->[0] + 0, name => $_->[1], alevel => $_->[2] + 0 } } @$rows ];
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

sub _summary_from_row {
  my ($kind, $row, $scope_id) = @_;
  my $cfg = $KIND{$kind};

  my %s;
  if ($kind eq 'hinfo') {
    my ($id, $hinfo, $type, $pri, $cdate, $cuser, $mdate, $muser) = @$row;
    %s = (id => $id + 0, hinfo => $hinfo, type => _hinfo_type_slug($type), pri => $pri + 0,
          cdate => $cdate, cuser => $cuser, mdate => $mdate, muser => $muser);
  } else {
    my ($id, $name, $comment, $cdate, $cuser, $mdate, $muser);
    my $alevel;
    if ($cfg->{has_alevel}) {
      ($id, $name, $comment, $alevel, $cdate, $cuser, $mdate, $muser) = @$row;
    } else {
      ($id, $name, $comment, $cdate, $cuser, $mdate, $muser) = @$row;
    }
    %s = (id => $id + 0, name => $name, comment => $comment,
          cdate => $cdate, cuser => $cuser, mdate => $mdate, muser => $muser);
    $s{alevel} = $alevel + 0 if $cfg->{has_alevel};
    $s{ $cfg->{scope_field} } = $scope_id if $cfg->{scope_field};
  }
  return _with_audit_strings(\%s);
}

sub _template_detail {
  my ($kind, $id, $scope_id, $data) = @_;
  my $cfg = $KIND{$kind};

  my %r;
  if ($kind eq 'hinfo') {
    %r = (id => $id + 0, hinfo => $data->{hinfo},
          type => _hinfo_type_slug($data->{type}), pri => $data->{pri} + 0);
  } else {
    %r = (id => $id + 0, name => $data->{name}, comment => $data->{comment});
    $r{alevel} = $data->{alevel} + 0 if $cfg->{has_alevel};
    $r{ $cfg->{scope_field} } = $scope_id if $cfg->{scope_field};
    if ($cfg->{entry_key}) {
      my $entries = $cfg->{codec}->decode($data->{ $cfg->{entry_key} });
      # wks_entries.proto is CHAR(10) and comes back space-padded.
      if ($kind eq 'wks') {
        for my $e (@$entries) { $e->{proto} =~ s/\s+$// if defined $e->{proto}; }
      }
      $r{ $cfg->{entry_key} } = $entries;
    }
    $r{host_count} = _host_count($cfg->{host_col}, $id) if $cfg->{host_col};
  }
  %r = (%r, cdate => $data->{cdate}, cuser => $data->{cuser},
             mdate => $data->{mdate}, muser => $data->{muser});
  return _with_audit_strings(\%r);
}

sub _host_count {
  my ($col, $id) = @_;
  my $rows = dbq("SELECT COUNT(*) FROM hosts WHERE $col=?", $id);
  return $rows->[0][0] + 0;
}

sub _with_audit_strings {
  my ($rec) = @_;
  # DBD::Pg returns int columns as strings via some fetch paths; the schema
  # declares cdate/mdate as integers, so coerce before response validation.
  $rec->{cdate} = defined $rec->{cdate} ? $rec->{cdate} + 0 : undef;
  $rec->{mdate} = defined $rec->{mdate} ? $rec->{mdate} + 0 : undef;
  Sauron::BackEnd::add_std_fields($rec);
  return $rec;
}

sub _require_name {
  my ($name) = @_;
  SauronAPI::Exception->validation("'name' is required")
    unless defined $name && length $name;
  return $name;
}

sub _require_printer_name {
  my ($name) = @_;
  SauronAPI::Exception->validation("'name' is required")
    unless defined $name && length $name;
  SauronAPI::Exception->validation("'name' must match ^\@[a-zA-Z]+\$")
    unless $name =~ /^\@[a-zA-Z]+$/;
  return $name;
}

sub _require_hinfo {
  my ($hinfo) = @_;
  SauronAPI::Exception->validation("'hinfo' is required")
    unless defined $hinfo && length $hinfo;
  SauronAPI::Exception->validation("'hinfo' must match ^[A-Z0-9-+/]+\$")
    unless $hinfo =~ /^[A-Z0-9\-\+\/]+$/;
  return $hinfo;
}

sub _validate_int_nonneg {
  my ($field, $v) = @_;
  SauronAPI::Exception->validation("'$field' must be a non-negative integer")
    unless defined $v && $v =~ /^\d+$/;
}

sub _hinfo_type_code {
  my ($type) = @_;
  return 0 if !defined $type || $type eq 'hardware';
  return 1 if $type eq 'software';
  SauronAPI::Exception->validation(
    "'type' must be one of: hardware, software");
}

sub _hinfo_type_slug {
  my ($type) = @_;
  return ($type // 0) == 1 ? 'software' : 'hardware';
}

sub _validate_entries {
  my ($kind, $input) = @_;
  my $key = $KIND{$kind}{entry_key};

  return unless exists $input->{$key};
  my $rows = $input->{$key};
  SauronAPI::Exception->validation("'$key' must be an array")
    unless ref $rows eq 'ARRAY';

  for my $row (@$rows) {
    SauronAPI::Exception->validation("'$key' entries must be objects")
      unless ref $row eq 'HASH';

    if ($kind eq 'mx') {
      SauronAPI::Exception->validation("'$key' entries require a 'pri'")
        unless defined $row->{pri} && $row->{pri} =~ /^\d+$/;
      SauronAPI::Exception->validation("'$key' entries require a non-empty 'mx'")
        unless defined $row->{mx} && $row->{mx} =~ /\S/;
    } elsif ($kind eq 'wks') {
      SauronAPI::Exception->validation("'$key' entries require a non-empty 'proto'")
        unless defined $row->{proto} && $row->{proto} =~ /\S/;
      # Note: legacy form allows an empty 'services' (empty=>[0,1,1]).
    } elsif ($kind eq 'printer') {
      SauronAPI::Exception->validation("'$key' entries require a non-empty 'printer'")
        unless defined $row->{printer} && $row->{printer} =~ /\S/;
    }
  }
}

1;
