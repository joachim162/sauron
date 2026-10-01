package SauronAPI::Controller::Templates::PrinterClass;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Repository::Template qw(
  printer_class_list printer_class_find printer_class_create printer_class_update printer_class_delete
);

# GET /printer-classes
sub list_printer_classes ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my ($classes, $meta) = eval {
    printer_class_list(
      page => $self->param('page') // 1, per_page => $self->param('per_page') // 50,
      $self->list_query_params);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $classes, metadata => $meta });
}

# GET /printer-classes/{id}
sub get_printer_class ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $class = eval { printer_class_find($self->param('id')) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $class);
}

# POST /printer-classes
sub create_printer_class ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $id = eval { printer_class_create($self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => printer_class_find($id), status => 201);
}

# PUT /printer-classes/{id}
sub update_printer_class ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  eval { printer_class_update($self->param('id'), $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => printer_class_find($self->param('id')));
}

# DELETE /printer-classes/{id}
sub delete_printer_class ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  eval { printer_class_delete($self->param('id')) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

1;
