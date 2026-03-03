package SauronAPI::Controller::Server;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Sauron::BackEnd;

# GET /servers
# List all servers managed by Sauron using legacy BackEnd logic
sub list_servers ($self) {
  my @ids;
  my %descriptions;

  # 1. Get the list of server IDs from the BackEnd
  # Passing -1 tells Sauron not to exclude any specific server
  get_server_list(-1, \%descriptions, \@ids);

  my @servers;
  for my $id (@ids) {
    # Skip the internal "None" marker (-1) used by the legacy UI
    next if $id == -1;

    # 2. Retrieve the full record for each server to ensure data integrity
    my %server_data;
    if (get_server($id, \%server_data) == 0) {
      push @servers, {
        id      => $id,
        name    => $server_data{name},
        comment => $server_data{comment} // ''
      };
    }
  }

  # 3. Render the JSON response validated against openapi.yaml
  $self->render(openapi => \@servers);
}

1;
