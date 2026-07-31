package SauronAPI::Controller::Server;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use SauronAPI::AuthZ qw(check_perms filter_servers);
use SauronAPI::Repository::Server qw(
  server_list server_find server_create server_update server_delete
);

# GET /servers
# List all servers managed by Sauron
sub list_servers ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $servers = server_list();

  my $perms = $self->stash('api_perms');
  my $superuser = $self->stash('api_superuser') // 0;
  filter_servers($perms, $superuser, $servers);

  $self->render(openapi => $servers);
}

# GET /servers/{server}
# Get server by name
sub get_server ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');

  my $server = eval { server_find($server_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $server);
}

# POST /servers
# Create a new server
sub add_server ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $server = eval { server_create($self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $server, status => 201);
}

# PUT /servers/{server}
# Update an existing server
sub update_server ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'RW');

  my $server = eval { server_update($server_id, $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $server);
}

# DELETE /servers/{server}
# Delete a server and all associated data
sub delete_server ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;

  eval { server_delete($server_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

1;
