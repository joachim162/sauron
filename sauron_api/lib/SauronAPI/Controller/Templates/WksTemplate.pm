package SauronAPI::Controller::Templates::WksTemplate;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Repository::Template qw(
  wks_template_list wks_template_find wks_template_create wks_template_update wks_template_delete
  assignable_wks_templates
);

# GET /servers/{server}/wks-templates
sub list_wks_templates ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');

  my ($templates, $meta) = eval {
    wks_template_list($server_id,
      page => $self->param('page') // 1, per_page => $self->param('per_page') // 50,
      $self->list_query_params);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $templates, metadata => $meta });
}

# GET /servers/{server}/wks-templates/{id}
sub get_wks_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');

  my $template = eval { wks_template_find($server_id, $self->param('id')) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $template);
}

# POST /servers/{server}/wks-templates
sub create_wks_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');

  my $id = eval { wks_template_create($server_id, $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => wks_template_find($server_id, $id), status => 201);
}

# PUT /servers/{server}/wks-templates/{id}
sub update_wks_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');

  eval { wks_template_update($server_id, $self->param('id'), $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => wks_template_find($server_id, $self->param('id')));
}

# DELETE /servers/{server}/wks-templates/{id}[?reassign_to=<id>]
sub delete_wks_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');

  eval { wks_template_delete($server_id, $self->param('id'), $self->param('reassign_to')) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

# GET /servers/{server}/assignable-wks-templates
sub list_assignable_wks_templates ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');

  my $superuser  = $self->stash('api_superuser');
  my $perms      = $self->stash('api_perms');
  my $max_alevel = $superuser ? undef : ($perms->{alevel} // 0);

  my $templates = eval { assignable_wks_templates($server_id, $max_alevel) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $templates);
}

1;
