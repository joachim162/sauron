package SauronAPI::Controller::Host;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::BackEnd ();
use Sauron::DB ();

# GET /hosts/{host}
# Get host by FQDN (Fully Qualified Domain Name)
# FQDN is expected to be like: www.example.com
sub get_host ($self) {
  return unless $self->openapi->valid_input;

  my $fqdn = $self->param("host");
  
  # Remove trailing dot if present
  $fqdn =~ s/\.$//;
  
  # Parse FQDN into domain and zone name
  # e.g., "www.example.com" -> domain="www", zone_name="example.com"
  my ($domain, $zone_name);
  if ($fqdn =~ /^([^\.]+)\.(.*)$/) {
    $domain = $1;
    $zone_name = $2;
  } else {
    return $self->render(
      openapi => {
        error   => 'Bad Request',
        message => "Invalid FQDN format: '$fqdn'"
      },
      status  => 400
    );
  }
  
  # Use a JOIN query to efficiently find host across all servers
  my $domain_q = Sauron::DB::db_encode_str($domain);
  my $zone_q = Sauron::DB::db_encode_str($zone_name);
  
  my @q;
  Sauron::DB::db_query(
    "SELECT h.id, h.zone, z.server, s.name " .
    "FROM hosts h " . "JOIN zones z ON h.zone = z.id " .
    "JOIN servers s ON z.server = s.id " .
    "WHERE h.domain = $domain_q AND z.name = $zone_q",
    \@q
  );
  
  if (@q == 0 || $q[0][0] <= 0) {
    return $self->render(
      openapi => {
        error   => 'Not Found',
        message => "Host '$fqdn' not found"
      },
      status  => 404
    );
  }
  
  my $host_id = $q[0][0];
  my $zone_id = $q[0][1];
  my $server_id = $q[0][2];
  my $server_name = $q[0][3];
  
  # Now get full host data
  my %host_data;
  if (Sauron::BackEnd::get_host($host_id, \%host_data) != 0) {
    return $self->render(
      openapi => {
        error   => 'Internal Server Error',
        message => Sauron::DB::db_errormsg()
      },
      status  => 500
    );
  }
  
  # Build response according to Host schema
  # Extract IP addresses from the ip array (skip header row)
  my @ips;
  if (ref $host_data{ip} eq 'ARRAY' && @{$host_data{ip}} > 1) {
    for my $i (1 .. $#{$host_data{ip}}) {
      push @ips, $host_data{ip}[$i][1] if defined $host_data{ip}[$i][1];
    }
  }
  
  my $res = {
    id        => $host_id,
    domain    => $host_data{domain},
    fqdn      => $host_data{fqdn} // "$domain.$zone_name.",
    zone_id   => $zone_id,
    server_id => $server_id,
    server    => $server_name,
    type      => $host_data{type},
    ips       => \@ips,
    ether     => $host_data{ether} // undef,
    model     => $host_data{model} // undef,
    serial    => $host_data{serial} // undef,
    asset_id  => $host_data{asset_id} // undef,
    comment   => $host_data{comment} // ''
  };
  
  $self->render(openapi => $res);
}

1;
