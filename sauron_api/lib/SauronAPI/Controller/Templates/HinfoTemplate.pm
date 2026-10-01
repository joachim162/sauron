package SauronAPI::Controller::Templates::HinfoTemplate;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Repository::Template qw(
  hinfo_template_list hinfo_template_find hinfo_template_create hinfo_template_update hinfo_template_delete
);

# GET /hinfo-templates
sub list_hinfo_templates ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my ($templates, $meta) = eval {
    hinfo_template_list(
      page => $self->param('page') // 1, per_page => $self->param('per_page') // 50,
      $self->list_query_params);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $templates, metadata => $meta });
}

# GET /hinfo-templates/{id}
sub get_hinfo_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $template = eval { hinfo_template_find($self->param('id')) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $template);
}

# POST /hinfo-templates
sub create_hinfo_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $id = eval { hinfo_template_create($self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => hinfo_template_find($id), status => 201);
}

# PUT /hinfo-templates/{id}
sub update_hinfo_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  eval { hinfo_template_update($self->param('id'), $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => hinfo_template_find($self->param('id')));
}

# DELETE /hinfo-templates/{id}
sub delete_hinfo_template ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  eval { hinfo_template_delete($self->param('id')) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

1;
