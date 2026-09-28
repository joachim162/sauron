package SauronAPI::Controller::Group;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Repository::Group qw(
  group_list group_find group_create group_update group_delete
  assignable_groups
);

# GET /servers/{server}/groups
# List the groups of a server (paginated, ungated — legacy browse parity).
sub list_groups ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');

  my $page     = $self->param('page')     // 1;
  my $per_page = $self->param('per_page') // 50;

  my ($groups, $meta) = eval {
    group_list($server_id,
      page => $page, per_page => $per_page,
      $self->list_query_params);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $groups, metadata => $meta });
}

# GET /servers/{server}/groups/{group}
# Get group details (summary + entry arrays + audit fields).
sub get_group ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  my $group_id = $self->get_group_id_or_404($server_id, $self->param('group')) or return;

  my $group = eval { group_find($server_id, $group_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $group);
}

# POST /servers/{server}/groups
sub create_group ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'RW');

  my $input = $self->req->json // {};
  return unless check_perms($self, type => 'grpmask', name => $input->{name});

  my $group = eval { group_create($server_id, $input) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $group, status => 201);
}

# PUT /servers/{server}/groups/{group}
# Partial update; `name` is both the path key and a mutable field.
sub update_group ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'RW');
  my $group_id = $self->get_group_id_or_404($server_id, $self->param('group')) or return;

  my $input = $self->req->json // {};
  return unless check_perms($self, type => 'grpmask', name => $self->param('group'));
  if (exists $input->{name} && $input->{name} ne $self->param('group')) {
    return unless check_perms($self, type => 'grpmask', name => $input->{name});
  }

  my $group = eval { group_update($server_id, $group_id, $input) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $group);
}

# DELETE /servers/{server}/groups/{group}[?reassign_to=<name>]
# Members are detached by default, or moved to `reassign_to` first.
sub delete_group ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'RW');
  my $group_id = $self->get_group_id_or_404($server_id, $self->param('group')) or return;
  return unless check_perms($self, type => 'grpmask', name => $self->param('group'));

  eval { group_delete($server_id, $group_id, reassign_to => $self->param('reassign_to')) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

# GET /servers/{server}/assignable-groups?role=base|subgroup
# Bare-array picker helper for the host forms (mirrors assignable-subnets).
sub list_assignable_groups ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');

  my $superuser = $self->stash('api_superuser');
  my $perms     = $self->stash('api_perms');
  my $max_alevel = $superuser ? undef : ($perms->{alevel} // 0);

  my $groups = eval {
    assignable_groups($server_id,
      role       => $self->param('role') // 'base',
      max_alevel => $max_alevel);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $groups);
}

1;
