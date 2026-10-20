package SauronAPI::Repository::User;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  user_list user_find user_self_update user_change_password user_is_active
  user_create user_update user_lock user_unlock user_reset_password user_remove
  user_right_list user_right_add user_right_delete user_group_list
);

use Sauron::BackEnd ();
use Sauron::DB ();
use Sauron::Util    ();
use SauronAPI::Exception  ();
use SauronAPI::ListQuery  qw(compile_filters parse_sort sort_sql sort_echo list_metadata set_total);
use SauronAPI::Repository qw(dbq with_statement_timeout LIST_STATEMENT_TIMEOUT_MS);
use Scalar::Util qw(blessed);
use JSON::PP ();

my %FILTER_SPEC = (
  username  => { kind => 'regex',  col => 'u.username' },
  name      => { kind => 'regex',  col => 'u.name' },
  email     => { kind => 'regex',  col => 'u.email' },
  comment   => { kind => 'regex',  col => 'u.comment' },
  superuser => { kind => 'bool', col => 'COALESCE(u.superuser,false)' },
  locked    => { kind => 'bool', col => "COALESCE(u.password LIKE 'LOCKED:%',false)" },
  closed    => { kind => 'bool', col => "COALESCE(u.password = 'LOCKED:REMOVED',false)" },
);

my %SORT_COLUMN = (
  username               => 'u.username',
  name                   => 'u.name',
  email                  => 'u.email',
  superuser              => 'COALESCE(u.superuser,false)',
  locked                 => "COALESCE(u.password LIKE 'LOCKED:%',false)",
  closed                 => "COALESCE(u.password = 'LOCKED:REMOVED',false)",
  expiration             => 'u.expiration',
  last_login_at          => 'u.last',
  last_password_change_at => 'u.last_pwd',
  cdate                  => 'u.cdate',
  mdate                  => 'u.mdate',
);

sub user_list {
  my (%opts) = @_;

  my $page     = $opts{page}     // 1;
  my $per_page = $opts{per_page} // 50;

  my $sort = parse_sort($opts{sort}, \%SORT_COLUMN,
    default => 'username', tiebreak => 'u.id');
  my $filters = compile_filters($opts{params} // {}, \%FILTER_SPEC);
  my $meta = list_metadata($page, $per_page, sort_echo($sort), $filters->{echo});

  return ([], $meta) if $filters->{empty};

  my @bind;
  my $where = '';
  if ($filters->{where}) {
    $where = " WHERE $filters->{where} ";
    push @bind, @{$filters->{bind}};
  }

  my ($rows, $count_rows);
  with_statement_timeout(LIST_STATEMENT_TIMEOUT_MS, sub {
    $rows = dbq(
      'SELECT ' . _select_columns() . " FROM users u $where "
      . sort_sql($sort) . ' LIMIT ? OFFSET ?',
      @bind, $per_page, ($page - 1) * $per_page
    );
    $count_rows = dbq("SELECT COUNT(*) FROM users u $where", @bind);
  });
  set_total($meta, $count_rows->[0][0] // 0);

  return ([ map { _build_user_response($_) } @$rows ], $meta);
}

sub user_find {
  my ($user_id) = @_;

  my $row = _user_row(_validate_user_id($user_id));
  return _build_user_response($row);
}

sub user_self_update {
  my ($user_id, $input) = @_;

  $user_id = _validate_user_id($user_id);
  my %allowed = map { $_ => 1 }
    qw(email email_notify default_server_id default_zone_id);
  for my $field (keys %$input) {
    SauronAPI::Exception->validation("Field '$field' cannot be changed here")
      unless $allowed{$field};
  }

  # A body without updatable fields is a no-op: legacy reports "No changes
  # made" and the request must not bump the audit columns.
  return user_find($user_id)
    unless grep { exists $input->{$_} } keys %allowed;

  my $row = _user_row($user_id);
  my %rec = (id => $user_id);

  if (exists $input->{email}) {
    my $email = $input->{email};
    if (defined $email && length $email) {
      _assert_unique_email($email, $user_id);
      $rec{email} = $email;
    } else {
      $rec{email} = undef;
    }
  }

  if (exists $input->{default_server_id} || exists $input->{default_zone_id}) {
    my ($server, $zone) = _validated_defaults($input, $row->[5], $row->[6]);
    $rec{server} = $server;
    $rec{zone}   = $zone;
  }

  $rec{email_notify} = exists $input->{email_notify}
    ? ($input->{email_notify} ? 1 : 0)
    : (((($row->[12] // 0) + 0) & 1) ? 1 : 0);

  my $res = Sauron::BackEnd::update_user(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence("Failed to update user (code: $res)");
  }

  return user_find($user_id);
}

sub user_change_password {
  my ($user_id, $current, $new) = @_;

  $user_id = _validate_user_id($user_id);
  SauronAPI::Exception->validation('current_password and new_password are required')
    unless defined $current && length $current && defined $new && length $new;

  my $row = _user_row($user_id);
  my $stored = $row->[2] // '';
  SauronAPI::Exception->conflict('Account has no local password') unless length $stored;
  SauronAPI::Exception->forbidden('Invalid current password')
    if Sauron::Util::pwd_check($current, $stored);

  my $hash = _password_hash($new);
  dbq('UPDATE users SET password=?, last_pwd=? WHERE id=? RETURNING id', $hash, time, $user_id);
  return;
}

sub _validate_user_id {
  my ($user_id) = @_;
  SauronAPI::Exception->validation('Invalid user ID (positive integer required)')
    unless defined $user_id && $user_id =~ /^[1-9][0-9]*$/;
  return $user_id + 0;
}

sub _user_row {
  my ($user_id, $lock) = @_;

  my $rows = dbq(
    "SELECT id,username,password,name,comment,server,zone,expiration,"
      . "email,last,last_pwd,superuser,flags,cdate,cuser,mdate,muser,last_from "
      . "FROM users WHERE id=?" . ($lock ? ' FOR UPDATE' : ''),
    $user_id
  );
  SauronAPI::Exception->not_found("User '$user_id' not found") unless @$rows;
  return $rows->[0];
}

sub _select_columns {
  return "u.id,u.username,u.password,u.name,u.comment,u.server,u.zone,"
    . "u.expiration,u.email,u.last,u.last_pwd,u.superuser,u.flags,"
    . "u.cdate,u.cuser,u.mdate,u.muser,u.last_from";
}

sub _build_user_response {
  my ($row) = @_;

  my %user = (
    id                         => $row->[0],
    username                   => $row->[1],
    name                       => $row->[3],
    comment                    => $row->[4],
    default_server_id          => _id_or_undef($row->[5]),
    default_zone_id            => _id_or_undef($row->[6]),
    expiration                 => defined $row->[7] ? $row->[7] + 0 : 0,
    email                      => $row->[8],
    last_login_at              => ($row->[9] && $row->[9] > 0) ? $row->[9] + 0 : undef,
    last_password_change_at    => ($row->[10] && $row->[10] > 0) ? $row->[10] + 0 : undef,
    last_login_from             => $row->[17],
    superuser                  => (($row->[11] // '') eq 't' ? JSON::PP::true : JSON::PP::false),
    email_notify               => (((($row->[12] // 0) + 0) & 1) ? JSON::PP::true : JSON::PP::false),
    cdate                      => defined $row->[13] ? $row->[13] + 0 : undef,
    cuser                      => $row->[14],
    mdate                      => defined $row->[15] ? $row->[15] + 0 : undef,
    muser                      => $row->[16],
  );

  my $password = $row->[2] // '';
  $user{closed} = $password eq 'LOCKED:REMOVED' ? JSON::PP::true : JSON::PP::false;
  $user{locked} = $password =~ /^LOCKED:/ ? JSON::PP::true : JSON::PP::false;

  return \%user;
}

sub _id_or_undef {
  my ($value) = @_;
  return (defined $value && $value > 0) ? $value + 0 : undef;
}

sub _validated_defaults {
  my ($input, $current_server, $current_zone) = @_;

  $current_server = -1 unless defined $current_server && $current_server > 0;
  $current_zone   = -1 unless defined $current_zone   && $current_zone   > 0;

  my $server = exists $input->{default_server_id}
    ? $input->{default_server_id}
    : $current_server;
  my $zone = exists $input->{default_zone_id}
    ? $input->{default_zone_id}
    : $current_zone;

  $server = -1 unless defined $server;
  $zone   = -1 unless defined $zone;

  if ($server > 0) {
    my $rows = dbq('SELECT id FROM servers WHERE id=?', $server);
    SauronAPI::Exception->validation(
      "Default server '$server' does not exist"
    ) unless @$rows;
  }

  if ($zone > 0) {
    my $rows = dbq('SELECT id,server FROM zones WHERE id=?', $zone);
    SauronAPI::Exception->validation(
      "Default zone '$zone' does not exist"
    ) unless @$rows;
    SauronAPI::Exception->validation(
      "Default zone '$zone' requires default_server_id"
    ) if $server < 1;
    SauronAPI::Exception->validation(
      "Default zone '$zone' does not belong to server '$server'"
    ) if $rows->[0][1] != $server;
  }

  return ($server, $zone);
}

sub _assert_unique_email {
  my ($email, $exclude_id) = @_;

  return unless defined $email && length $email;
  SauronAPI::Exception->validation("Invalid email format")
    unless $email =~ /^[^\@\s]+\@[^\@\s]+\.[^\@\s]+$/;

  my $rows = dbq(
    'SELECT id FROM users WHERE email=? AND id<>?',
    $email, $exclude_id // -1
  );
  SauronAPI::Exception->conflict("Email '$email' is already in use") if @$rows;
}

sub user_is_active {
  my ($user_id) = @_;
  return 0 unless defined $user_id && $user_id =~ /^[1-9][0-9]*$/;
  return @{dbq(
    "SELECT id FROM users WHERE id=? AND COALESCE(password,'') NOT ILIKE 'LOCKED:%' "
      . "AND (COALESCE(expiration,0)<=0 OR expiration>extract(epoch FROM now()))", $user_id
  )} ? 1 : 0;
}

sub _password_hash {
  my ($password) = @_;
  SauronAPI::Exception->validation('A non-empty password is required')
    unless defined $password && !ref $password && length $password;
  my $mode = do { no warnings 'once'; $main::SAURON_PWD_MODE // 1 };
  if ($mode == 1) {
    my $bytes = $password;
    utf8::encode($bytes) if utf8::is_utf8($bytes);
    SauronAPI::Exception->validation(
      'Password is longer than 8 bytes; password mode 1 (Unix crypt) would truncate it'
    ) if length($bytes) > 8;
  }
  return Sauron::Util::pwd_make($password, $mode);
}

sub _admin_transaction {
  my ($actor_id, $code) = @_;
  $actor_id = _validate_user_id($actor_id);
  SauronAPI::Exception->persistence('Failed to start transaction') unless Sauron::DB::db_begin();
  my $result;
  my $ok = eval {
    dbq('SELECT pg_advisory_xact_lock(73191,1)');
    my $actor = _user_row($actor_id, 1);
    SauronAPI::Exception->forbidden('Active administrator privileges required')
      unless ($actor->[11] // '') eq 't' && user_is_active($actor_id);
    Sauron::BackEnd::set_muser($actor->[1]);
    Sauron::DB::db_ignore_begin_and_commit(1);
    $result = $code->($actor);
    1;
  };
  my $err = $@;
  Sauron::DB::db_ignore_begin_and_commit(0);
  unless ($ok) {
    Sauron::DB::db_rollback();
    die $err if blessed($err) && $err->isa('SauronAPI::Exception');
    SauronAPI::Exception->persistence('Administrative change failed');
  }
  unless (Sauron::DB::db_commit()) {
    Sauron::DB::db_rollback();
    SauronAPI::Exception->persistence('Failed to commit administrative change');
  }
  return $result;
}

sub _open_user {
  my ($user_id) = @_;
  my $row = _user_row(_validate_user_id($user_id), 1);
  SauronAPI::Exception->conflict('Closed accounts cannot be changed')
    if ($row->[2] // '') eq 'LOCKED:REMOVED';
  return $row;
}

sub _audit {
  my ($actor, $row, $action, $changes) = @_;
  my $info = JSON::PP->new->canonical->encode({
    actor => $actor->[1], username => $row->[1], changes => $changes // {},
  });
  SauronAPI::Exception->persistence('Failed to record administrative history')
    if Sauron::BackEnd::update_history($actor->[0], -1, 5, $action, $info, $row->[0]) < 0;
}

sub _save_user {
  my ($row, $rec) = @_;
  $rec->{id} = $row->[0];
  $rec->{email_notify} = (($row->[12] // 0) & 1) ? 1 : 0 unless exists $rec->{email_notify};
  SauronAPI::Exception->persistence('Failed to update user')
    if Sauron::BackEnd::update_user($rec) < 0;
}

sub _revoke_credentials {
  my ($user_id) = @_;
  dbq('DELETE FROM bff_sessions WHERE user_id=? RETURNING user_id', $user_id);
  dbq('DELETE FROM personal_access_tokens WHERE user_id=? RETURNING id', $user_id);
  dbq('DELETE FROM utmp WHERE uid=? RETURNING uid', $user_id);
}

sub _guard_admin {
  my ($actor, $row, $rec, $removing) = @_;
  my $super = exists $rec->{superuser} ? $rec->{superuser} eq 't' : ($row->[11] // '') eq 't';
  my $password = exists $rec->{password} ? $rec->{password} : $row->[2];
  my $expiration = exists $rec->{expiration} ? $rec->{expiration} : $row->[7];
  my $losing = $removing || !$super || ($password // '') =~ /^LOCKED:/i
    || (($expiration // 0) > 0 && $expiration <= time);
  if ($actor->[0] == $row->[0]) {
    SauronAPI::Exception->conflict('Cannot disable or demote your own account')
      if $losing || (exists $rec->{expiration} && $rec->{expiration} > 0);
  }
  return unless $losing;
  my $others = dbq(
    "SELECT COUNT(*) FROM users WHERE id<>? AND superuser=true "
      . "AND COALESCE(password,'') NOT ILIKE 'LOCKED:%' "
      . "AND (COALESCE(expiration,0)<=0 OR expiration>extract(epoch FROM now()))", $row->[0]
  );
  SauronAPI::Exception->conflict('Cannot remove the last active superuser') unless $others->[0][0] > 0;
}

sub _allowed_fields {
  my ($input, $allowed) = @_;
  SauronAPI::Exception->validation('An object is required') unless ref $input eq 'HASH';
  for my $field (keys %$input) {
    SauronAPI::Exception->validation("Field '$field' cannot be changed here") unless $allowed->{$field};
  }
}

sub _account_fields {
  my ($input, $row, $creating) = @_;
  my %allowed = map { $_ => 1 } qw(username name email comment superuser email_notify
    default_server_id default_zone_id expiration);
  $allowed{password} = 1 if $creating;
  _allowed_fields($input, \%allowed);
  my %rec;
  if ($creating || exists $input->{username}) {
    my $name = $input->{username};
    SauronAPI::Exception->validation('Username must match [a-z0-9.@-]+')
      unless defined $name && $name =~ /^[a-z0-9.\@-]+$/;
    my $found = dbq('SELECT id FROM users WHERE username=? AND id<>?', $name, $row ? $row->[0] : -1);
    SauronAPI::Exception->conflict('Username already exists') if @$found;
    $rec{username} = $name;
  }
  for my $field (qw(name comment)) {
    $rec{$field} = $input->{$field} if exists $input->{$field};
  }
  if (exists $input->{email}) {
    _assert_unique_email($input->{email}, $row ? $row->[0] : -1);
    $rec{email} = length($input->{email} // '') ? $input->{email} : undef;
  }
  $rec{superuser} = $input->{superuser} ? 't' : 'f' if exists $input->{superuser};
  $rec{email_notify} = $input->{email_notify} ? 1 : 0 if exists $input->{email_notify};
  if (exists $input->{expiration}) {
    my $exp = $input->{expiration} // 0;
    SauronAPI::Exception->validation('Expiration must be a non-negative Unix timestamp')
      unless $exp =~ /^\d+$/ && $exp <= 2147483647;
    $rec{expiration} = $exp + 0;
  }
  if ($creating || exists $input->{default_server_id} || exists $input->{default_zone_id}) {
    my ($server, $zone) = _validated_defaults($input, $row ? $row->[5] : -1, $row ? $row->[6] : -1);
    $rec{server} = $server;
    $rec{zone} = $zone;
  }
  return \%rec;
}

sub user_create {
  my ($actor_id, $input) = @_;
  return _admin_transaction($actor_id, sub {
    my ($actor) = @_;
    my $rec = _account_fields($input, undef, 1);
    $rec->{password} = exists $input->{password} ? _password_hash($input->{password}) : undef;
    $rec->{last_pwd} = exists $input->{password} ? time : 0;
    my $id = Sauron::BackEnd::add_user($rec);
    SauronAPI::Exception->persistence('Failed to create user') unless $id > 0;
    my $row = _user_row($id);
    my %changes = %$input;
    delete $changes{password};
    _audit($actor, $row, 'ADD: User', \%changes);
    return _build_user_response($row);
  });
}

sub user_update {
  my ($actor_id, $user_id, $input) = @_;
  return _admin_transaction($actor_id, sub {
    my ($actor) = @_;
    my $row = _open_user($user_id);
    my $rec = _account_fields($input, $row, 0);
    return _build_user_response($row) unless keys %$rec;
    _guard_admin($actor, $row, $rec, 0);
    _save_user($row, $rec);
    _audit($actor, $row, 'UPDATE: User', $input);
    return user_find($user_id);
  });
}

sub user_lock {
  my ($actor_id, $user_id) = @_;
  return _admin_transaction($actor_id, sub {
    my ($actor) = @_;
    my $row = _open_user($user_id);
    SauronAPI::Exception->conflict('Account is already locked') if ($row->[2] // '') =~ /^LOCKED:/i;
    my %rec = (password => 'LOCKED:' . ($row->[2] // ''));
    _guard_admin($actor, $row, \%rec, 0);
    _save_user($row, \%rec);
    _revoke_credentials($user_id);
    _audit($actor, $row, 'LOCK: User');
    return user_find($user_id);
  });
}

sub user_unlock {
  my ($actor_id, $user_id) = @_;
  return _admin_transaction($actor_id, sub {
    my ($actor) = @_;
    my $row = _open_user($user_id);
    my $password = $row->[2] // '';
    SauronAPI::Exception->conflict('Account is not locked') unless $password =~ s/^LOCKED://i;
    _save_user($row, {password => length $password ? $password : undef});
    _audit($actor, $row, 'UNLOCK: User');
    return user_find($user_id);
  });
}

sub user_reset_password {
  my ($actor_id, $user_id, $input) = @_;
  _allowed_fields($input, {password => 1});
  return _admin_transaction($actor_id, sub {
    my ($actor) = @_;
    my $row = _open_user($user_id);
    my $hash = _password_hash($input->{password});
    $hash = 'LOCKED:' . $hash if ($row->[2] // '') =~ /^LOCKED:/i;
    _save_user($row, {password => $hash, last_pwd => time});
    _revoke_credentials($user_id);
    _audit($actor, $row, 'PASSWORD: User');
    return user_find($user_id);
  });
}

sub user_remove {
  my ($actor_id, $user_id, $delete) = @_;
  return _admin_transaction($actor_id, sub {
    my ($actor) = @_;
    my $row = $delete ? _user_row(_validate_user_id($user_id), 1) : _open_user($user_id);
    SauronAPI::Exception->conflict('Only locked or expired accounts can be closed or deleted')
      unless ($row->[2] // '') =~ /^LOCKED:/i || (($row->[7] // 0) > 0 && $row->[7] <= time);
    _guard_admin($actor, $row, {}, 1);
    _revoke_credentials($user_id);
    dbq('DELETE FROM user_rights WHERE type=2 AND ref=? RETURNING id', $user_id);
    if ($delete) {
      dbq('DELETE FROM users WHERE id=? RETURNING id', $user_id);
    } else {
      my $now = time;
      my $expiration = ($row->[7] // 0) > $now ? $row->[7] : $now;
      dbq(
        'UPDATE users SET server=DEFAULT,zone=DEFAULT,superuser=DEFAULT,last_pwd=DEFAULT,flags=DEFAULT,'
          . 'email=NULL,last_from=NULL,search_opts=NULL,comment=NULL,'
          . 'name=?,password=?,expiration=?,mdate=?,muser=? WHERE id=? RETURNING id',
        'Removed User', 'LOCKED:REMOVED', $expiration, $now, $actor->[1], $user_id
      );
    }
    _audit($actor, $row, ($delete ? 'DELETE' : 'ANONYMIZE') . ': User');
    return $delete ? undef : user_find($user_id);
  });
}

my @RIGHT_KINDS = qw(group server zone net hostmask ipmask level elimit defdept tmplmask grpmask delmask rhf flag defhost);
my %RIGHT_TYPE = map { $RIGHT_KINDS[$_] => $_ } 0..$#RIGHT_KINDS;
my %RIGHT_FIELDS = (
  group => [qw(group_id)], server => [qw(server_id mode)], zone => [qw(zone_id mode)],
  net => [qw(net_id)], hostmask => [qw(pattern zone_id)], delmask => [qw(pattern zone_id)],
  ipmask => [qw(pattern)], tmplmask => [qw(pattern)], grpmask => [qw(pattern)],
  level => [qw(value)], elimit => [qw(value)], defdept => [qw(value)], defhost => [qw(value)],
  rhf => [qw(field required)], flag => [qw(value)],
);

sub _right_record {
  my ($input) = @_;
  my $kind = $input->{kind} // '';
  SauronAPI::Exception->validation('Invalid permission rule kind') unless exists $RIGHT_TYPE{$kind};
  _allowed_fields($input, {map { $_ => 1 } ('kind', @{$RIGHT_FIELDS{$kind}})});
  my ($ref, $rule) = (-1, '');
  if ($kind =~ /^(group|server|zone|net)$/) {
    my %tables = (group => 'user_groups', server => 'servers', zone => 'zones', net => 'nets');
    $ref = _validate_user_id($input->{"${kind}_id"});
    SauronAPI::Exception->validation("Referenced $kind does not exist")
      unless @{dbq("SELECT id FROM $tables{$kind} WHERE id=?", $ref)};
    if ($kind eq 'server' || $kind eq 'zone') {
      $rule = $input->{mode} // '';
      SauronAPI::Exception->validation('Mode must be R, RW, or RWX') unless $rule =~ /^(R|RW|RWX)$/;
    } elsif ($kind eq 'net') {
      $rule = 'unused';
    }
  } elsif ($kind =~ /^(hostmask|delmask|tmplmask|grpmask|ipmask)$/) {
    $rule = $input->{pattern};
    SauronAPI::Exception->validation('A non-empty pattern is required') unless defined $rule && length $rule;
    if (($kind eq 'hostmask' || $kind eq 'delmask') && defined $input->{zone_id}) {
      $ref = _validate_user_id($input->{zone_id});
      SauronAPI::Exception->validation('Referenced zone does not exist') unless @{dbq('SELECT id FROM zones WHERE id=?', $ref)};
    }
    if ($kind eq 'ipmask') {
      SauronAPI::Exception->validation('Invalid IP mask') unless Sauron::Util::check_ipmask($rule, '') == 1;
    } else {
      my $ok = eval { qr/$rule/; 1 };
      SauronAPI::Exception->validation('Invalid permission regular expression') unless $ok;
    }
  } elsif ($kind eq 'rhf') {
    $rule = $input->{field} // '';
    SauronAPI::Exception->validation('Invalid required-host field')
      unless $rule =~ /^(huser|dept|location|info|ether|duid|asset_id|model|serial|misc)$/;
    SauronAPI::Exception->validation('required must be supplied') unless exists $input->{required};
    $ref = $input->{required} ? 0 : 1;
  } else {
    $rule = $input->{value};
    SauronAPI::Exception->validation('A value is required') unless defined $rule && length "$rule";
    if ($kind eq 'level' || $kind eq 'elimit') {
      SauronAPI::Exception->validation('Value must be a non-negative integer') unless $rule =~ /^\d+$/;
      SauronAPI::Exception->validation('Authorization level must be 0..999') if $kind eq 'level' && $rule > 999;
      $rule = 0 + $rule;
    } elsif ($kind eq 'flag') {
      $rule = uc $rule;
      SauronAPI::Exception->validation('Invalid privilege flag')
        unless $rule =~ /^(CNAME|SCNAME|AREC|MX|DELEG|GLUE|DHCP|PRINTER|SRV|SSHFP|TLSA|NAPTR|RESERV|TTL)$/;
    } elsif ($kind eq 'defdept') {
      $rule =~ s/^\s+|\s+$//g;
      SauronAPI::Exception->validation('Default department must not be empty') unless length $rule;
    } elsif ($kind eq 'defhost') {
      $rule =~ s/\s//g;
      SauronAPI::Exception->validation('Default hostname template must contain %{id}') unless $rule =~ /%\{id\}/;
    }
  }
  SauronAPI::Exception->validation('Permission values cannot exceed 80 characters') if length "$rule" > 80;
  return ($RIGHT_TYPE{$kind}, $ref, "$rule");
}

sub _right_response {
  my ($row) = @_;
  my ($id, $type, $ref, $rule, $group_id, $group_name) = @$row;
  $rule //= '';
  $rule =~ s/\s+$//;
  my $kind = $type >= 0 && $type <= $#RIGHT_KINDS ? $RIGHT_KINDS[$type] : 'legacy';
  my %out = (id => 0 + $id, kind => $kind, source => defined $group_id ? 'inherited' : 'direct',
    source_group_id => defined $group_id ? 0 + $group_id : undef, source_group_name => $group_name);
  if ($kind =~ /^(group|server|zone|net)$/) {
    $out{"${kind}_id"} = 0 + $ref;
    $out{mode} = $rule if $kind eq 'server' || $kind eq 'zone';
  } elsif ($kind =~ /^(hostmask|delmask|tmplmask|grpmask|ipmask)$/) {
    $out{pattern} = $rule;
    $out{zone_id} = $ref > 0 ? 0 + $ref : undef if $kind eq 'hostmask' || $kind eq 'delmask';
  } elsif ($kind eq 'rhf') {
    $out{field} = $rule;
    $out{required} = $ref ? JSON::PP::false : JSON::PP::true;
  } elsif ($kind eq 'legacy') {
    @out{qw(legacy_type legacy_ref value)} = ($type + 0, $ref + 0, $rule);
  } else {
    $out{value} = ($kind eq 'level' || $kind eq 'elimit') && $rule =~ /^\d+$/ ? 0 + $rule : $rule;
  }
  return \%out;
}

sub user_right_list {
  my ($user_id, %opts) = @_;
  _user_row(_validate_user_id($user_id));
  SauronAPI::Exception->validation('Sorting is fixed for user rights') if exists $opts{params}{sort};
  compile_filters($opts{params} // {}, {});
  my $page = $opts{page} // 1;
  my $per_page = $opts{per_page} // 50;
  my $sql = 'SELECT r.id,r.rtype,r.rref,r.rule,NULL::integer AS group_id,NULL::text AS group_name '
    . 'FROM user_rights r WHERE r.type=2 AND r.ref=? UNION ALL '
    . 'SELECT r.id,r.rtype,r.rref,r.rule,g.id,g.name FROM user_rights r '
    . 'JOIN user_groups g ON r.type=1 AND r.ref=g.id '
    . 'WHERE EXISTS (SELECT 1 FROM user_rights m WHERE m.type=2 AND m.ref=? AND m.rtype=0 AND m.rref=g.id)';
  my $rows = dbq("SELECT * FROM ($sql) rights ORDER BY group_id NULLS FIRST,id LIMIT ? OFFSET ?",
    $user_id, $user_id, $per_page, ($page - 1) * $per_page);
  my $count = dbq("SELECT COUNT(*) FROM ($sql) rights", $user_id, $user_id);
  my $meta = list_metadata($page, $per_page, [], []);
  set_total($meta, $count->[0][0]);
  return ([map { _right_response($_) } @$rows], $meta);
}

sub user_right_add {
  my ($actor_id, $user_id, $input) = @_;
  return _admin_transaction($actor_id, sub {
    my ($actor) = @_;
    my $row = _open_user($user_id);
    my ($type, $ref, $rule) = _right_record($input);
    SauronAPI::Exception->conflict('Direct permission rule already exists') if @{dbq(
      "SELECT id FROM user_rights WHERE type=2 AND ref=? AND rtype=? AND rref=? AND COALESCE(rule,'')=?",
      $user_id, $type, $ref, $rule)};
    my $id = Sauron::BackEnd::add_record('user_rights', {
      type => 2, ref => $user_id, rtype => $type, rref => $ref, rule => $rule,
    });
    SauronAPI::Exception->persistence('Failed to add permission rule') unless $id > 0;
    _save_user($row, {});
    my $result = _right_response([$id, $type, $ref, $rule, undef, undef]);
    _audit($actor, $row, 'ADD: User right', $result);
    return $result;
  });
}

sub user_right_delete {
  my ($actor_id, $user_id, $right_id) = @_;
  return _admin_transaction($actor_id, sub {
    my ($actor) = @_;
    my $row = _open_user($user_id);
    my @bind = ($user_id);
    my $where = 'type=2 AND ref=?';
    if (defined $right_id) {
      $where .= ' AND id=?';
      push @bind, _validate_user_id($right_id);
    }
    my $removed = dbq("DELETE FROM user_rights WHERE $where RETURNING id,rtype,rref,rule", @bind);
    SauronAPI::Exception->not_found('Direct permission rule not found') if defined $right_id && !@$removed;
    if (@$removed) {
      _save_user($row, {});
      _audit($actor, $row, 'REMOVE: User rights', {rights => [map { _right_response([@$_, undef, undef]) } @$removed]});
    }
    return;
  });
}

sub user_group_list {
  my (%opts) = @_;
  my $page = $opts{page} // 1;
  my $per_page = $opts{per_page} // 50;
  SauronAPI::Exception->validation('Sorting is fixed for user groups') if exists $opts{params}{sort};
  compile_filters($opts{params} // {}, {});
  my $rows = dbq('SELECT id,name,comment FROM user_groups ORDER BY name,id LIMIT ? OFFSET ?',
    $per_page, ($page - 1) * $per_page);
  my $meta = list_metadata($page, $per_page, [], []);
  set_total($meta, dbq('SELECT COUNT(*) FROM user_groups')->[0][0]);
  return ([map { +{id => 0 + $_->[0], name => $_->[1], comment => $_->[2]} } @$rows], $meta);
}

1;
