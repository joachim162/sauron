package SauronAPI::Controller::Templates::MxTemplate;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Repository::Template qw(
  mx_template_list mx_template_find mx_template_create mx_template_update mx_template_delete
  assignable_mx_templates
);

# GET /servers/{server}/zones/{zone}/mx-templates
sub list_mx_templates ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  my $zone_id = $self->get_zone_id_or_404($server_id, $self->param('zone')) or return;

  my ($templates, $meta) = eval {
    mx_template_list($zone_id,
      page => $self->param('page') // 1, per_page => $self->param('per_page') // 50,
      $self->list_query_params);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $templates, metadata => $meta });
}

# GET /servers/{server}/zones/{zone}/mx-templates/{id}
sub get_mx_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  my $zone_id = $self->get_zone_id_or_404($server_id, $self->param('zone')) or return;

  my $template = eval { mx_template_find($zone_id, $self->param('id')) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $template);
}

# POST /servers/{server}/zones/{zone}/mx-templates
sub create_mx_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  my $zone_id = $self->get_zone_id_or_404($server_id, $self->param('zone')) or return;

  my $input = $self->req->json // {};
  return unless check_perms($self, type => 'tmplmask', name => $input->{name});

  my $id = eval { mx_template_create($zone_id, $input) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => mx_template_find($zone_id, $id), status => 201);
}

# PUT /servers/{server}/zones/{zone}/mx-templates/{id}
sub update_mx_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  my $zone_id = $self->get_zone_id_or_404($server_id, $self->param('zone')) or return;

  my $existing = eval { mx_template_find($zone_id, $self->param('id')) };
  return $self->render_exception($@) if $@;
  return unless check_perms($self, type => 'tmplmask', name => $existing->{name});

  my $input = $self->req->json // {};
  if (exists $input->{name} && $input->{name} ne $existing->{name}) {
    return unless check_perms($self, type => 'tmplmask', name => $input->{name});
  }

  eval { mx_template_update($zone_id, $self->param('id'), $input) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => mx_template_find($zone_id, $self->param('id')));
}

# DELETE /servers/{server}/zones/{zone}/mx-templates/{id}[?reassign_to=<id>]
sub delete_mx_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  my $zone_id = $self->get_zone_id_or_404($server_id, $self->param('zone')) or return;

  my $existing = eval { mx_template_find($zone_id, $self->param('id')) };
  return $self->render_exception($@) if $@;
  return unless check_perms($self, type => 'tmplmask', name => $existing->{name});

  eval { mx_template_delete($zone_id, $self->param('id'), $self->param('reassign_to')) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

# GET /servers/{server}/zones/{zone}/assignable-mx-templates
sub list_assignable_mx_templates ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  my $zone_id = $self->get_zone_id_or_404($server_id, $self->param('zone')) or return;

  my $superuser  = $self->stash('api_superuser');
  my $perms      = $self->stash('api_perms');
  my $max_alevel = $superuser ? undef : ($perms->{alevel} // 0);

  my $templates = eval { assignable_mx_templates($zone_id, $max_alevel) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $templates);
}

1;
