package SauronAPI::Repository::User;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  user_list user_find user_self_update user_change_password
);

use Sauron::BackEnd ();
use Sauron::Util    ();
use SauronAPI::Exception  ();
use SauronAPI::ListQuery  qw(compile_filters parse_sort sort_sql sort_echo list_metadata set_total);
use SauronAPI::Repository qw(dbq with_statement_timeout LIST_STATEMENT_TIMEOUT_MS);
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

  my $mode = do { no warnings 'once'; $main::SAURON_PWD_MODE // 1 };
  if ($mode == 1) {
    my $bytes = $new;
    utf8::encode($bytes) if utf8::is_utf8($bytes);
    SauronAPI::Exception->validation(
      'new_password is longer than 8 bytes; password mode 1 (Unix crypt) would truncate it'
    ) if length($bytes) > 8;
  }

  my $hash = Sauron::Util::pwd_make($new, $mode);
  dbq('UPDATE users SET password=?, last_pwd=? WHERE id=?', $hash, time, $user_id);
  return;
}

sub _validate_user_id {
  my ($user_id) = @_;
  SauronAPI::Exception->validation('Invalid user ID (positive integer required)')
    unless defined $user_id && $user_id =~ /^[1-9][0-9]*$/;
  return $user_id + 0;
}

sub _user_row {
  my ($user_id) = @_;

  my $rows = dbq(
    "SELECT id,username,password,name,comment,server,zone,expiration,"
      . "email,last,last_pwd,superuser,flags,cdate,cuser,mdate,muser "
      . "FROM users WHERE id=?",
    $user_id
  );
  SauronAPI::Exception->not_found("User '$user_id' not found") unless @$rows;
  return $rows->[0];
}

sub _select_columns {
  return "u.id,u.username,u.password,u.name,u.comment,u.server,u.zone,"
    . "u.expiration,u.email,u.last,u.last_pwd,u.superuser,u.flags,"
    . "u.cdate,u.cuser,u.mdate,u.muser";
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

1;
