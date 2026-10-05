package SauronAPI::Controller::Acl;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::Sauron ();
use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Repository::Acl qw(acl_list acl_find acl_create acl_update acl_delete);

# Reads require server R + ALEVEL_ACLS; writes require superuser (legacy CGI
# parity, Sauron/CGI/ACLs.pm, ADR 0011). Singletons resolve server-owned ACLs
# only — a built-in name (server=-1) is a 404, mirroring the legacy
# non-clickable "(Built-in)" rows.

# GET /servers/{server}/acls
sub list_acls ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  return unless check_perms($self, type => 'level', level => $main::ALEVEL_ACLS);

  my $page     = $self->param('page')     // 1;
  my $per_page = $self->param('per_page') // 50;

  my ($acls, $meta) = eval {
    acl_list($server_id,
      page => $page, per_page => $per_page,
      $self->list_query_params);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $acls, metadata => $meta });
}

# GET /servers/{server}/acls/{acl}
sub get_acl ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  return unless check_perms($self, type => 'level', level => $main::ALEVEL_ACLS);
  my $acl_id = $self->get_acl_id_or_404($server_id, $self->param('acl')) or return;

  my $acl = eval { acl_find($server_id, $acl_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $acl);
}

# POST /servers/{server}/acls
sub create_acl ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');

  my $acl = eval { acl_create($server_id, $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $acl, status => 201);
}

# PUT /servers/{server}/acls/{acl}
sub update_acl ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');
  my $acl_id = $self->get_acl_id_or_404($server_id, $self->param('acl')) or return;

  my $acl = eval { acl_update($server_id, $acl_id, $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $acl);
}

# DELETE /servers/{server}/acls/{acl}
sub delete_acl ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');
  my $acl_id = $self->get_acl_id_or_404($server_id, $self->param('acl')) or return;

  eval { acl_delete($server_id, $acl_id, scalar $self->param('reassign_to')) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

1;
