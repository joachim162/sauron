package SauronAPITest;
use Mojo::Base -strict;
use Exporter qw(import);

use Sauron::Sauron;
use Sauron::BackEnd;
use Sauron::Util;
use Sauron::DB qw(db_connect db_exec);
use Test::Mojo;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

# Force Sauron to load t/config instead of system config
# Use absolute path so do() works even when '.' is not in @INC
BEGIN {
  my $test_dir = dirname(abs_path(__FILE__));
  $Sauron::Sauron::CONF_FILE_PATH = dirname($test_dir);
}

our @EXPORT_OK = qw(
  setup_test_app
  create_test_user
  delete_test_user
  create_test_server
  delete_test_server
  create_test_zone
  delete_test_zone
  grant_server_access
  grant_zone_access
  grant_rhf
  make_pat
  db_exec
);

# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------

sub setup_test_app {
  my $t = Test::Mojo->new('SauronAPI');
  return $t;
}

# ---------------------------------------------------------------------------
# User fixtures
# ---------------------------------------------------------------------------

sub create_test_user {
  my (%args) = @_;

  Sauron::BackEnd::set_muser('test');

  my $password = $args{password} // 'testpass';
  my $pwd_hash = Sauron::Util::pwd_make($password, $main::SAURON_PWD_MODE // 1);

  my $id = Sauron::BackEnd::add_record('users', {
    username  => $args{username} // 'testuser',
    password  => $pwd_hash,
    name      => $args{name}     // 'Test User',
    email     => $args{email}    // 'test@example.com',
    superuser => ($args{superuser} ? 't' : 'f'),
    flags     => 0,
  });

  die "Failed to create test user: $id" unless $id > 0;
  return $id;
}

# TODO: Backend already implements this
sub delete_test_user {
  my ($user_id) = @_;
  return unless $user_id && $user_id > 0;
  db_exec("DELETE FROM user_rights WHERE type=2 AND ref=$user_id");
  db_exec("DELETE FROM bff_sessions WHERE user_id=$user_id");
  db_exec("DELETE FROM personal_access_tokens WHERE user_id=$user_id");
  db_exec("DELETE FROM users WHERE id=$user_id");
}

# ---------------------------------------------------------------------------
# Server fixtures
# ---------------------------------------------------------------------------

sub create_test_server {
  my (%args) = @_;

  Sauron::BackEnd::set_muser('test');

  my $id = Sauron::BackEnd::add_server({
    name    => $args{name}    // 'test-server',
    comment => $args{comment} // 'Test server for API tests',
  });

  die "Failed to create test server: $id" unless $id > 0;
  return $id;
}

sub delete_test_server {
  my ($server_id) = @_;
  return unless $server_id && $server_id > 0;
  Sauron::BackEnd::delete_server($server_id);
}

# ---------------------------------------------------------------------------
# Zone fixtures
# ---------------------------------------------------------------------------

sub create_test_zone {
  my (%args) = @_;

  Sauron::BackEnd::set_muser('test');

  my $id = Sauron::BackEnd::add_zone({
    server => $args{server_id} // die('server_id required'),
    name   => $args{name}      // 'test-zone.example.com',
    type   => $args{type}      // 'M',
    active => 't',
  });

  die "Failed to create test zone: $id" unless $id > 0;
  return $id;
}

sub delete_test_zone {
  my ($zone_id) = @_;
  return unless $zone_id && $zone_id > 0;
  Sauron::BackEnd::delete_zone($zone_id);
}

# ---------------------------------------------------------------------------
# Permission fixtures
# ---------------------------------------------------------------------------

# rtype: 1=server, 2=zone
sub grant_server_access {
  my ($user_id, $server_id, $rule) = @_;
  my $res = Sauron::BackEnd::add_record('user_rights', {
    type => 2,
    ref  => $user_id,
    rtype => 1,
    rref  => $server_id,
    rule  => $rule,
  });
  die "Failed to grant server access: $res" unless $res > 0;
}

sub grant_zone_access {
  my ($user_id, $zone_id, $rule) = @_;
  my $res = Sauron::BackEnd::add_record('user_rights', {
    type => 2,
    ref  => $user_id,
    rtype => 2,
    rref  => $zone_id,
    rule  => $rule,
  });
  die "Failed to grant zone access: $res" unless $res > 0;
}

sub grant_rhf {
  my ($user_id, $field, $rref) = @_;
  # rref: 0 = required, non-zero = optional
  my $res = Sauron::BackEnd::add_record('user_rights', {
    type => 2,
    ref  => $user_id,
    rtype => 12,
    rref  => $rref // 0,
    rule  => $field,
  });
  die "Failed to grant RHF: $res" unless $res > 0;
}

# ---------------------------------------------------------------------------
# PAT fixtures
# ---------------------------------------------------------------------------

sub make_pat {
  my ($user_id, $name) = @_;
  my %rec;
  my $res = Sauron::BackEnd::create_pat($user_id, $name, \%rec);
  die "Failed to create PAT: $res" unless $res == 0;
  return $rec{plain_token};
}

1;
