package SauronAPI::Repository::Acl;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(acl_list acl_find acl_create acl_update acl_delete);

use Scalar::Util ();
use Sauron::BackEnd ();
use Sauron::Util    qw(is_cidr);
use Sauron::DB      ();
use SauronAPI::Codecs     qw(aml);
use SauronAPI::Exception  ();
use SauronAPI::ListQuery  qw(compile_filters parse_sort sort_sql sort_echo list_metadata set_total);
use SauronAPI::Repository qw(dbq check_rc with_statement_timeout LIST_STATEMENT_TIMEOUT_MS);
use JSON::PP ();

my $AML = aml();

my %FILTER_SPEC = (
  name    => { kind => 'regex', col => 'name' },
  comment => { kind => 'regex', col => 'comment' },
);

my %SORT_COLUMN = (
  name    => 'name',
  comment => 'comment',
);

# ---------------------------------------------------------------------------
# List: server-owned ACLs plus the global built-ins (server=-1) in one query
# (ADR 0011; legacy browse_acls / get_acl_list both include the built-ins).
# ---------------------------------------------------------------------------

sub acl_list {
  my ($server_id, %opts) = @_;

  my $page     = $opts{page}     // 1;
  my $per_page = $opts{per_page} // 50;

  my $sort = parse_sort($opts{sort}, \%SORT_COLUMN, default => 'name', tiebreak => 'id');
  my $filters = compile_filters($opts{params} // {}, \%FILTER_SPEC);
  my $meta = list_metadata($page, $per_page, sort_echo($sort), $filters->{echo});

  return ([], $meta) if $filters->{empty};

  my @bind = ($server_id);
  my $where = ' WHERE (server=? OR server=-1) ';
  if ($filters->{where}) {
    $where .= " AND $filters->{where} ";
    push @bind, @{$filters->{bind}};
  }

  my ($rows, $count_rows);
  with_statement_timeout(LIST_STATEMENT_TIMEOUT_MS, sub {
    $rows = dbq(
      "SELECT id,server,name,comment,cdate,cuser,mdate,muser FROM acls $where "
      . sort_sql($sort) . ' LIMIT ? OFFSET ?',
      @bind, $per_page, ($page - 1) * $per_page
    );
    $count_rows = dbq("SELECT COUNT(*) FROM acls $where", @bind);
  });
  set_total($meta, $count_rows->[0][0] // 0);

  my $acls = [ map { _build_summary($_) } @$rows ];
  return ($acls, $meta);
}

# ---------------------------------------------------------------------------
# Single record
# ---------------------------------------------------------------------------

sub acl_find {
  my ($server_id, $acl_id) = @_;

  my %data;
  check_rc(Sauron::BackEnd::get_acl($acl_id, \%data),
         'Failed to retrieve ACL data');
  SauronAPI::Exception->not_found('ACL not found on this server')
    unless $data{server} == $server_id;

  return _build_detail($acl_id, \%data);
}

sub acl_create {
  my ($server_id, $input) = @_;

  my $name = _require_name($input->{name});
  _assert_unique_name($server_id, $name, undef);
  my $members = _validate_members($server_id, $input, undef);

  my %rec = (
    server  => $server_id,
    name    => $name,
    comment => $input->{comment},
  );
  my $encoded = $members ? $AML->encode_create($members) : undef;
  $rec{acl} = $encoded if ref $encoded eq 'ARRAY';

  SauronAPI::Exception->persistence('Failed to start transaction')
    unless Sauron::DB::db_begin();

  my $acl_id;
  my $ok = eval {
    Sauron::DB::db_ignore_begin_and_commit(1);
    my $res = eval { Sauron::BackEnd::add_acl(\%rec) };
    my $err = $@;
    Sauron::DB::db_ignore_begin_and_commit(0);
    die $err if $err;
    die "add_acl failed (code: $res)" if $res < 0;
    $acl_id = $res;
    1;
  };
  my $err = $@;

  if (!$ok) {
    Sauron::DB::db_rollback();
    die $err if Scalar::Util::blessed($err) && $err->isa('SauronAPI::Exception');
    SauronAPI::Exception->persistence("Failed to create ACL ($err)");
  }
  SauronAPI::Exception->persistence('Failed to commit ACL creation')
    unless Sauron::DB::db_commit();

  my %data;
  check_rc(Sauron::BackEnd::get_acl($acl_id, \%data),
         'ACL created but failed to retrieve data');

  return _build_detail($acl_id, \%data);
}

sub acl_update {
  my ($server_id, $acl_id, $input) = @_;

  my %existing;
  check_rc(Sauron::BackEnd::get_acl($acl_id, \%existing),
         'Failed to retrieve existing ACL data');

  my %rec = (id => $acl_id);

  if (exists $input->{name}) {
    my $name = _require_name($input->{name});
    _assert_unique_name($server_id, $name, $acl_id);
    $rec{name} = $name;
  }
  if (exists $input->{comment}) {
    $rec{comment} = $input->{comment};
  }

  my $members = _validate_members($server_id, $input, $acl_id);
  if ($members) {
    my $data = $AML->encode_update($members, $existing{acl});
    $rec{acl} = $data if ref $data eq 'ARRAY';
  }

  my $res = Sauron::BackEnd::update_acl(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence("Failed to update ACL (code: $res)");
  }

  my %data;
  check_rc(Sauron::BackEnd::get_acl($acl_id, \%data),
         'ACL updated but failed to retrieve data');

  return _build_detail($acl_id, \%data);
}

# Corrected delete (ADR 0011): reassigning/detaching referencing rows covers
# ALL cidr_entries pointing at the ACL, including type=0 rows nested inside
# other ACLs' bodies — BackEnd::delete_acl only reassigns type>0 rows and
# leaves nested references dangling (issue #53).
sub acl_delete {
  my ($server_id, $acl_id, $reassign_to) = @_;

  my $newref = -1;
  if (defined $reassign_to) {
    SauronAPI::Exception->validation("'reassign_to' must be a positive integer")
      unless "$reassign_to" =~ /^\d+$/ && $reassign_to > 0;
    SauronAPI::Exception->validation(
      "'reassign_to' must differ from the ACL being deleted"
    ) if $reassign_to == $acl_id;
    my %ref_acl;
    my $rc = Sauron::BackEnd::get_acl($reassign_to, \%ref_acl);
    SauronAPI::Exception->validation(
      "'reassign_to' is not an ACL on this server"
    ) if $rc != 0 || (%ref_acl && $ref_acl{server} != $server_id && $ref_acl{server} != -1);
    $newref = $reassign_to;
  }

  SauronAPI::Exception->persistence('Failed to start transaction')
    unless Sauron::DB::db_begin();

  my $ok = eval {
    dbq('UPDATE cidr_entries SET acl=? WHERE acl=?', $newref, $acl_id);
    Sauron::DB::db_ignore_begin_and_commit(1);
    my $res = eval { Sauron::BackEnd::delete_acl($acl_id, $newref) };
    my $err = $@;
    Sauron::DB::db_ignore_begin_and_commit(0);
    die $err if $err;
    die "delete_acl failed (code: $res)" if $res < 0;
    1;
  };
  my $err = $@;

  if (!$ok) {
    Sauron::DB::db_rollback();
    die $err if Scalar::Util::blessed($err) && $err->isa('SauronAPI::Exception');
    SauronAPI::Exception->persistence('Failed to delete ACL');
  }
  SauronAPI::Exception->persistence('Failed to commit ACL deletion')
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

sub _assert_unique_name {
  my ($server_id, $name, $self_id) = @_;
  my $existing = Sauron::BackEnd::get_acl_by_name($server_id, $name);
  return unless $existing > 0;
  return if defined $self_id && $existing == $self_id;
  SauronAPI::Exception->conflict("ACL '$name' already exists on this server");
}

# Per-mode member rules (ADR 0011; legacy parity with the ftype-12 checks in
# Sauron/CGIutil.pm, tightened: existence of acl/tkey targets, mode range, op
# range). Fields inapplicable to the mode are normalized rather than
# rejected. $self_id is the ACL being edited (undef on create) and drives the
# acyclicity rule: nested references must point to ACLs created earlier.
sub _validate_members {
  my ($server_id, $input, $self_id) = @_;
  return undef unless exists $input->{acl};

  my $rows = $input->{acl};
  SauronAPI::Exception->validation("'acl' must be an array")
    unless ref $rows eq 'ARRAY';

  my $i = 0;
  for my $el (@$rows) {
    $i++;
    SauronAPI::Exception->validation("acl[$i]: entry must be an object")
      unless ref $el eq 'HASH';

    my $mode = $el->{mode};
    SauronAPI::Exception->validation("acl[$i]: 'mode' must be 0 (CIDR), 1 (ACL), or 2 (key)")
      unless defined $mode && "$mode" =~ /^\d+$/ && $mode >= 0 && $mode <= 2;

    my $op = defined $el->{op} ? $el->{op} : 0;
    SauronAPI::Exception->validation("acl[$i]: 'op' must be 0 or 1")
      unless "$op" =~ /^\d+$/ && $op <= 1;
    $el->{op} = $op;

    if ($mode == 0) {
      my $ip = $el->{ip};
      SauronAPI::Exception->validation("acl[$i]: 'ip' must be a valid CIDR/IP")
        unless defined $ip && length $ip && is_cidr($ip);
      $el->{acl} = undef;
      $el->{tkey} = undef;
    }
    elsif ($mode == 1) {
      my $target = $el->{acl};
      SauronAPI::Exception->validation("acl[$i]: 'acl' is required")
        unless defined $target && "$target" =~ /^\d+$/ && $target > 0;
      my %ref;
      my $rc = eval { Sauron::BackEnd::get_acl($target, \%ref) };
      SauronAPI::Exception->validation("acl[$i]: 'acl' $target not found on this server")
        if $@ || $rc != 0 || !%ref
           || ($ref{server} != $server_id && $ref{server} != -1);
      SauronAPI::Exception->validation(
        "acl[$i]: cannot reference ACL $target; nested references must point to ACLs created before this one"
      ) if defined $self_id && $ref{server} != -1 && $target >= $self_id;
      $el->{ip} = undef;
      $el->{tkey} = undef;
    }
    else {
      my $target = $el->{tkey};
      SauronAPI::Exception->validation("acl[$i]: 'tkey' is required")
        unless defined $target && "$target" =~ /^\d+$/ && $target > 0;
      my %key;
      my $rc = eval { Sauron::BackEnd::get_key($target, \%key) };
      SauronAPI::Exception->validation("acl[$i]: 'tkey' $target is not a key on this server")
        if $@ || $rc != 0 || !%key || $key{type} != 1 || $key{ref} != $server_id;
      $el->{ip} = undef;
      $el->{acl} = undef;
    }
  }

  return $rows;
}

sub _ref_count {
  my ($acl_id) = @_;
  my $rows = dbq('SELECT COUNT(*) FROM cidr_entries WHERE acl=?', $acl_id);
  return $rows->[0][0] + 0;
}

# DBD::Pg returns int columns as strings via some fetch paths; the schema
# declares them integers, so coerce before response validation.
sub _with_audit_strings {
  my ($rec) = @_;
  $rec->{cdate} = defined $rec->{cdate} ? $rec->{cdate} + 0 : undef;
  $rec->{mdate} = defined $rec->{mdate} ? $rec->{mdate} + 0 : undef;
  Sauron::BackEnd::add_std_fields($rec);
  return $rec;
}

sub _build_summary {
  my ($row) = @_;
  my ($id, $server, $name, $comment, $cdate, $cuser, $mdate, $muser) = @$row;

  return _with_audit_strings({
    id        => $id + 0,
    server_id => $server + 0,
    name      => $name,
    comment   => $comment,
    builtin   => ($server == -1 ? JSON::PP::true : JSON::PP::false),
    cdate     => $cdate,
    cuser     => $cuser,
    mdate     => $mdate,
    muser     => $muser,
  });
}

sub _build_detail {
  my ($acl_id, $data) = @_;

  return _with_audit_strings({
    id        => $acl_id + 0,
    server_id => $data->{server} + 0,
    name      => $data->{name},
    comment   => $data->{comment},
    builtin   => ($data->{server} == -1 ? JSON::PP::true : JSON::PP::false),
    acl       => $AML->decode($data->{acl}),
    ref_count => _ref_count($acl_id),
    cdate     => $data->{cdate},
    cuser     => $data->{cuser},
    mdate     => $data->{mdate},
    muser     => $data->{muser},
  });
}

1;
