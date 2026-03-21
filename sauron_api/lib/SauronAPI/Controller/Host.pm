package SauronAPI::Controller::Host;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::BackEnd ();

# GET /hosts/{host}
# Get host by FQDN (Fully Qualified Domain Name)
# FQDN is expected to be like: www.example.com
sub get_host ($self) {
  return unless $self->openapi->valid_input;

  my $fqdn = $self->param("host");

  # Basic validation
  unless ($fqdn && $fqdn =~ /\./) {
    return $self->render(
      openapi => {
        error   => 'Bad Request',
        message => "Invalid FQDN format: '$fqdn'"
      },
      status  => 400
    );
  }

  # Look up host ID via BackEnd
  my $host_id = Sauron::BackEnd::get_host_id_by_fqdn($fqdn);
  if ($host_id <= 0) {
    return $self->render(
      openapi => {
        error   => 'Not Found',
        message => "Host '$fqdn' not found"
      },
      status  => 404
    );
  }

  # Get full host data
  my %host_data;
  if (Sauron::BackEnd::get_host($host_id, \%host_data) != 0) {
    return $self->render(
      openapi => {
        error   => 'Internal Server Error',
        message => "Failed to retrieve host data"
      },
      status  => 500
    );
  }

  # Resolve zone and server info
  my %zone_data;
  my $zone_id = $host_data{zone};
  my ($server_id, $server_name) = (0, '');
  # TODO: Check what happens if get_zone won't return 0
  if ($zone_id > 0 && Sauron::BackEnd::get_zone($zone_id, \%zone_data) == 0) {
    $server_id = $zone_data{server};
    my %server_data;
    if ($server_id > 0 && Sauron::BackEnd::get_server($server_id, \%server_data) == 0) {
      $server_name = $server_data{name};
    }
  }

  # Extract IP addresses from the ip array (skip header row)
  my @ips;
  if (ref $host_data{ip} eq 'ARRAY' && @{$host_data{ip}} > 1) {
    for my $i (1 .. $#{$host_data{ip}}) {
      push @ips, $host_data{ip}[$i][1] if defined $host_data{ip}[$i][1];
    }
  }

  my $res = {
    id         => $host_id,
    domain     => $host_data{domain},
    fqdn       => $host_data{fqdn} // '',
    zone_id    => $zone_id,
    server_id  => $server_id,
    server     => $server_name,
    type       => $host_data{type},
    ttl        => $host_data{ttl},
    class      => $host_data{class},
    grp        => $host_data{grp},
    alias      => $host_data{alias},
    cname_txt  => $host_data{cname_txt},
    hinfo_hw   => $host_data{hinfo_hw},
    hinfo_sw   => $host_data{hinfo_sw},
    router     => $host_data{router},
    ips        => \@ips,
    ether      => $host_data{ether},
    ether_alias => $host_data{ether_alias},
    info       => $host_data{info},
    location   => $host_data{location},
    dept       => $host_data{dept},
    huser      => $host_data{huser},
    email      => $host_data{email},
    model      => $host_data{model},
    serial     => $host_data{serial},
    misc       => $host_data{misc},
    asset_id   => $host_data{asset_id},
    dhcp_date  => $host_data{dhcp_date},
    dhcp_info  => $host_data{dhcp_info},
    comment    => $host_data{comment},
    duid       => $host_data{duid},
    iaid       => $host_data{iaid},
    flags      => $host_data{flags},
    cdate      => $host_data{cdate},
    cuser      => $host_data{cuser},
    mdate      => $host_data{mdate},
    muser      => $host_data{muser},
    expiration => $host_data{expiration}
  };

  $self->render(openapi => $res);
}

1;
