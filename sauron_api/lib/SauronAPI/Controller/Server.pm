package SauronAPI::Controller::Server;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::BackEnd ();
use Sauron::DB ();

# GET /servers
# List all servers managed by Sauron
sub list_servers ($self) {
  my @ids;
  my %descriptions;

  Sauron::BackEnd::get_server_list(-1, \%descriptions, \@ids);

  my @servers;
  for my $id (@ids) {
    next if $id == -1;

    my %server_data;
    if (Sauron::BackEnd::get_server($id, \%server_data) == 0) {
      push @servers, {
        id      => $id,
        name    => $server_data{name},
        comment => $server_data{comment} // ''
      };
    }
  }

  $self->render(openapi => \@servers);
}

# GET /servers/{server}
# Get server by name
sub get_server ($self) {
  my %server_data;

  return unless $self->openapi->valid_input;

  my $name = $self->param("server");

  my $id = $self->get_server_id_or_404($name) or return;

  if (Sauron::BackEnd::get_server($id, \%server_data) != 0) {
    return $self->render(
      openapi => {
        error   => 'Internal Server Error',
        message => Sauron::DB::db_errormsg()
      },
      status  => 500
    );
  }

  # Map to schema
  my $res = {
    id      => $id,
    name    => $server_data{name},
    comment => $server_data{comment} // ''
  };

  $self->render(openapi => $res);
}

1;
