package SauronAPI::AuthZ;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(check_perms has_server_access has_zone_access filter_servers filter_zones);

sub check_perms {
  my ($c, %args) = @_;

  my $perms = $c->stash('api_perms');
  unless ($perms) {
    $c->render(json => { error => 'Unauthorized', message => 'Not authenticated' }, status => 401);
    return 0;
  }

  my $superuser = $c->stash('api_superuser') // 0;

  my $type = delete $args{type};

  if ($superuser) {
    return 1;
  }

  if ($type eq 'superuser') {
    $c->render(json => { error => 'Forbidden', message => 'Administrator privileges required' }, status => 403);
    return 0;
  }

  if ($type eq 'level') {
    my $required = $args{level};
    my $alevel = $perms->{alevel} // 0;
    if ($alevel >= $required) {
      return 1;
    }
    $c->render(json => { error => 'Forbidden', message => 'Insufficient authorization level' }, status => 403);
    return 0;
  }

  if ($type eq 'server') {
    my $server_id = $args{server_id};
    my $rule = $args{rule};
    my $access = $perms->{server}{$server_id} // '';
    if ($access =~ /$rule/) {
      return 1;
    }
    $c->render(json => { error => 'Forbidden', message => 'Insufficient server access' }, status => 403);
    return 0;
  }

  if ($type eq 'zone') {
    my $zone_id = $args{zone_id};
    my $rule = $args{rule};
    my $server_id = $args{server_id};

    if ($main::SAURON_PRIVILEGE_MODE == 0 && defined $server_id) {
      my $server_access = $perms->{server}{$server_id} // '';
      if ($server_access =~ /$rule/) {
        return 1;
      }
    }

    my $zone_access = $perms->{zone}{$zone_id} // '';
    if ($zone_access =~ /$rule/) {
      return 1;
    }
    $c->render(json => { error => 'Forbidden', message => 'Insufficient zone access' }, status => 403);
    return 0;
  }

  if ($type eq 'host' || $type eq 'delhost') {
    my $hostname = $args{hostname};
    my $zone_id = $args{zone_id};
    my $server_id = $args{server_id};

    my $server_access = $perms->{server}{$server_id} // '';
    if ($server_access =~ /RW/) {
      return 1;
    }

    my $zone_access = $perms->{zone}{$zone_id} // '';
    if ($zone_access =~ /RW/) {
      my @hostmasks = @{$perms->{hostname} // []};
      if (@hostmasks == 0) {
        return 1;
      }
      for my $mask (@hostmasks) {
        my ($mask_zid, $regex) = @$mask;
        next if ($mask_zid != -1 && $mask_zid != $zone_id);
        if ($hostname =~ /$regex/) {
          return 1;
        }
      }
    }

    if ($type eq 'delhost') {
      my @delmasks = @{$perms->{delmask} // []};
      for my $mask (@delmasks) {
        my ($mask_zid, $regex) = @$mask;
        next if ($mask_zid != -1 && $mask_zid != $zone_id);
        if ($hostname =~ /$regex/) {
          return 1;
        }
      }
    }

    $c->render(json => { error => 'Forbidden', message => 'Not authorized to modify this host' }, status => 403);
    return 0;
  }

  if ($type eq 'flags') {
    my $flag = $args{flag};
    if ($perms->{flags}{$flag}) {
      return 1;
    }
    $c->render(json => { error => 'Forbidden', message => "Not authorized for record type: $flag" }, status => 403);
    return 0;
  }

  $c->render(json => { error => 'Forbidden', message => 'Access denied' }, status => 403);
  return 0;
}

sub has_server_access {
  my ($perms, $server_id, $rule) = @_;
  my $access = $perms->{server}{$server_id} // '';
  return $access =~ /$rule/;
}

sub has_zone_access {
  my ($perms, $zone_id, $server_id, $rule) = @_;
  if ($main::SAURON_PRIVILEGE_MODE == 0 && defined $server_id) {
    my $server_access = $perms->{server}{$server_id} // '';
    if ($server_access =~ /$rule/) {
      return 1;
    }
  }
  my $zone_access = $perms->{zone}{$zone_id} // '';
  return $zone_access =~ /$rule/;
}

sub filter_servers {
  my ($perms, $superuser, $servers_ref) = @_;
  return if $superuser;
  my @filtered;
  for my $s (@$servers_ref) {
    my $id = $s->{id};
    my $access = $perms->{server}{$id} // '';
    push @filtered, $s if $access =~ /R/i;
  }
  @$servers_ref = @filtered;
}

sub filter_zones {
  my ($perms, $superuser, $server_id, $zones_ref) = @_;
  return if $superuser;
  my @filtered;
  for my $z (@$zones_ref) {
    my $zid = $z->{id};
    if (has_zone_access($perms, $zid, $server_id, 'R')) {
      push @filtered, $z;
    }
  }
  @$zones_ref = @filtered;
}

1;