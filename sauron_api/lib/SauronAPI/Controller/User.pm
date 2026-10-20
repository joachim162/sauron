package SauronAPI::Controller::User;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Exception ();
use SauronAPI::Repository::User qw(
  user_list user_find user_create user_update user_lock user_unlock
  user_reset_password user_remove user_right_list user_right_add
  user_right_delete user_group_list
);

sub list_users ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $page     = $self->param('page')     // 1;
  my $per_page = $self->param('per_page') // 50;

  my ($users, $meta) = eval {
    user_list(
      page => $page, per_page => $per_page,
      $self->list_query_params);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $users, metadata => $meta });
}

sub get_user ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $user_id = $self->param('id');
  SauronAPI::Exception->forbidden('Insufficient access')
    unless $self->stash('api_superuser')
        || $user_id == ($self->stash('api_user_id') // 0);

  my $user = eval { user_find($user_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $user);
}

sub create_user ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $input = $self->req->json // {};
  if (exists $input->{password}) {
    my $mode = $self->app->config->{auth}{mode} // 'password';
    SauronAPI::Exception->forbidden('Local-password administration is not enabled')
      unless $mode eq 'password' || $mode eq 'both';
  }

  my $user = eval { user_create($self->stash('api_user_id'), $input) };
  return $self->render_exception($@) if $@;

  $self->res->headers->location(
    $self->url_for('get_user', id => $user->{id})->to_string);
  $self->render(openapi => $user, status => 201);
}

sub update_user ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $user_id = $self->param('id');
  my $user = eval {
    user_update($self->stash('api_user_id'), $user_id, $self->req->json // {});
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $user);
}

sub lock_user ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $user_id = $self->param('id');
  my $user = eval { user_lock($self->stash('api_user_id'), $user_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $user);
}

sub unlock_user ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $user_id = $self->param('id');
  my $user = eval { user_unlock($self->stash('api_user_id'), $user_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $user);
}

sub reset_password ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $mode = $self->app->config->{auth}{mode} // 'password';
  SauronAPI::Exception->forbidden('Local-password administration is not enabled')
    unless $mode eq 'password' || $mode eq 'both';

  my $user_id = $self->param('id');
  my $user = eval {
    user_reset_password($self->stash('api_user_id'), $user_id, $self->req->json // {});
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $user);
}

sub close_user ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $user_id = $self->param('id');
  my $user = eval { user_remove($self->stash('api_user_id'), $user_id, 0) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $user);
}

sub delete_user ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $user_id = $self->param('id');
  eval { user_remove($self->stash('api_user_id'), $user_id, 1) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

sub list_rights ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $user_id  = $self->param('id');
  my $page     = $self->param('page')     // 1;
  my $per_page = $self->param('per_page') // 50;

  my ($rights, $meta) = eval {
    user_right_list($user_id,
      page => $page, per_page => $per_page,
      $self->list_query_params);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $rights, metadata => $meta });
}

sub add_right ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $user_id = $self->param('id');
  my $right = eval {
    user_right_add($self->stash('api_user_id'), $user_id, $self->req->json // {});
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $right, status => 201);
}

sub delete_right ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $user_id  = $self->param('id');
  my $right_id = $self->param('right_id');

  eval { user_right_delete($self->stash('api_user_id'), $user_id, $right_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

sub list_user_groups ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $page     = $self->param('page')     // 1;
  my $per_page = $self->param('per_page') // 50;

  my ($groups, $meta) = eval {
    user_group_list(
      page => $page, per_page => $per_page,
      $self->list_query_params);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $groups, metadata => $meta });
}

1;
