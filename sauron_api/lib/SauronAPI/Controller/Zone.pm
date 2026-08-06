package SauronAPI::Controller::Zone;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use SauronAPI::AuthZ qw(check_perms visible_zone_ids);
use SauronAPI::Repository::Zone qw(
  zone_list zone_find zone_create zone_update zone_delete
);

# GET /servers/{server}/zones
# List the zones of a server (paginated, permission-filtered via allowlist)
sub list_zones ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;

  my $perms = $self->stash('api_perms');
  my $superuser = $self->stash('api_superuser') // 0;
  my $ids = visible_zone_ids($perms, $superuser, $server_id);

  my $page     = $self->param('page')     // 1;
  my $per_page = $self->param('per_page') // 50;

  my ($zones, $meta) = eval {
    zone_list($server_id, ids => $ids, page => $page, per_page => $per_page)
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $zones, metadata => $meta });
}

# GET /servers/{server}/zones/{zone}
# Get zone details
sub get_zone ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  my $zone_id   = $self->get_zone_id_or_404($server_id, $self->param("zone")) or return;
  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'R');

  my $zone = eval { zone_find($zone_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $zone);
}

# POST /servers/{server}/zones
# Create a new zone
sub create_zone ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'RW');

  my $zone = eval { zone_create($server_id, $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $zone, status => 201);
}

# PUT /servers/{server}/zones/{zone}
# Update an existing zone
sub update_zone ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  my $zone_id   = $self->get_zone_id_or_404($server_id, $self->param("zone")) or return;
  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'RW');

  my $zone = eval { zone_update($zone_id, $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $zone);
}

# DELETE /servers/{server}/zones/{zone}
# Delete a zone and all associated data
sub delete_zone ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'RWS');

  my $zone_id = $self->get_zone_id_or_404($server_id, $self->param("zone")) or return;

  eval { zone_delete($zone_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

1;
