package SauronAPI::Controller::Zone;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::BackEnd ();
use Sauron::DB ();
use Sauron::Util ();

# POST /servers/{server}/zones
# Create new zone
sub create_zone ($self) {
  return unless $self->openapi->valid_input;

  my $json = $self->req->json;
  my $server = $self->param("server");

  my $server_id = Sauron::BackEnd::get_server_id($server);
  if ($server_id <= 0) {
    return $self->render(
      openapi => {
        error   => 'Not Found',
        message => "Server '$server' not found"
      },
      status  => 404
    );
  }

  my $zone = $json->{name};
  my $raw_type  = $json->{type} // 'Master';
  my $type      = substr($raw_type, 0, 1);
  my $reverse   = $json->{reverse} ? 1 : 0;

  my %data = (
    server => $server_id,
    name   => $zone,
    type   => $type
  );

  if ($reverse) {
    $data{reverse} = 't';
    # Convert CIDR to arpa format if necessary
    if (Sauron::Util::is_cidr($data{name}) && $data{name} =~ /\/\d{1,3}$/) {
      $data{name} = Sauron::Util::cidr2arpa($data{name});
    }

    my $new_net = Sauron::Util::arpa2cidr($data{name});
    if ($new_net eq '0.0.0.0/0') {
      return $self->render(
        openapi => {
          error   => 'Bad Request',
          message => "Invalid name '$zone' for reverse zone"
        },
        status  => 400
      );
    }
    $data{reversenet} = $new_net;
  }

  my $existing_id = Sauron::BackEnd::get_zone_id($zone, $server_id);
  if ($existing_id > 0) {
    return $self->render(
      openapi => {
        error   => 'Conflict',
        message => "Zone '$zone' already exists on server '$server'"
      },
      status  => 409
    );
  }

  my $new_zone_id = Sauron::BackEnd::add_zone(\%data);
  if ($new_zone_id < 0) {
    return $self->render(
      openapi => {
        error   => 'Internal Server Error',
        message => "Failed to create zone record (Result code: $new_zone_id)"
      },
      status  => 500
    );
  }

  $self->render(
    openapi => {
      id        => $new_zone_id,
      name      => $data{name},
      server_id => $server_id,
      type      => $type,
      reverse   => $reverse ? Mojo::JSON->true : Mojo::JSON->false
    },
    status => 201
  );
}

# DELETE /servers/{server}/zones/{zone}
# Delete zone
sub delete_zone ($self) {
  return unless $self->openapi->valid_input;

  my $server = $self->param("server");
  my $zone = $self->param("zone");

  my $server_id = Sauron::BackEnd::get_server_id($server);
  if ($server_id <= 0) {
    return $self->render(
      openapi => {
        error   => 'Not Found',
        message => "Server '$server' not found"
      },
      status  => 404
    );
  }

  my $zone_id = Sauron::BackEnd::get_zone_id($zone, $server_id);
  if ($zone_id <= 0) {
    return $self->render(
      openapi => {
        error   => 'Not Found',
        message => "Zone '$zone' not found"
      },
      status  => 404
    );
  }

  my $res = Sauron::BackEnd::delete_zone($zone_id);
  if ($res < 0) {
    return $self->render(
      openapi => {
        error   => 'Internal Server Error',
        message => "Failed to delete zone record (Result code: $res)"
      },
      status  => 500
    );
  }

  # 3. Return status
  $self->render(openapi => undef, status => 204);
}

1;
