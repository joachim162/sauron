package SauronAPI::AuthZ;

use strict;
use warnings;
use Exporter qw(import);
use Net::IP qw(:PROC);
use Sauron::Util qw(is_cidr);

our @EXPORT_OK = qw(check_perms visible_server_ids visible_zone_ids);

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

  if ($type eq 'ip') {
    my $ip = $args{rule};
    my @net_ids = keys %{$perms->{net} // {}};
    return 1 if @net_ids == 0;  # no net restrictions → allowed

    my $ip_int;
    eval { $ip_int = Net::IP->new($ip)->intip(); };
    return 1 unless defined $ip_int;

    for my $net_id (@net_ids) {
      my ($range_start, $range_end) = @{$perms->{net}->{$net_id}};
      next unless is_cidr($range_start) && is_cidr($range_end);
      my $s = eval { Net::IP->new($range_start)->intip() };
      my $e = eval { Net::IP->new($range_end)->intip() };
      next unless defined $s && defined $e;
      if ($s <= $ip_int && $ip_int <= $e) {
        return 1;
      }
    }
    $c->render(json => { error => 'Forbidden', message => "IP address '$ip' is outside your allowed ranges" }, status => 403);
    return 0;
  }

  $c->render(json => { error => 'Forbidden', message => 'Access denied' }, status => 403);
  return 0;
}

# Visible object IDs for list endpoints (ADR 0004). Return undef when the
# request is unfiltered (superuser, or zones under PRIVILEGE_MODE 0 with a
# server grant) and an arrayref (possibly empty) of allowed IDs otherwise.
# The rule matching transcribes the former filter_servers/filter_zones
# exactly, including the case-sensitivity difference.
sub visible_server_ids {
  my ($perms, $superuser) = @_;
  return undef if $superuser;
  return [ grep { ($perms->{server}{$_} // '') =~ /R/i } keys %{$perms->{server} // {}} ];
}

sub visible_zone_ids {
  my ($perms, $superuser, $server_id) = @_;
  return undef if $superuser;
  if ($main::SAURON_PRIVILEGE_MODE == 0 && defined $server_id) {
    my $server_access = $perms->{server}{$server_id} // '';
    return undef if $server_access =~ /R/;
  }
  return [ grep { ($perms->{zone}{$_} // '') =~ /R/ } keys %{$perms->{zone} // {}} ];
}

1;