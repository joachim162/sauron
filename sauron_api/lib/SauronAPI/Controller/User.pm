package SauronAPI::Controller::User;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Repository::User qw(user_list user_find);

# /users is a read-only browsing resource. Listing requires superuser; a user
# may read their own record.

sub list_users ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;
  return unless check_perms($self, type => 'superuser');

  my $page     = $self->param('page')     // 1;
  my $per_page = $self->param('per_page') // 50;

  my ($users, $meta) = eval {
    user_list(
      page => $page, per_page => $per_page,
      $self->list_query_params
    );
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $users, metadata => $meta });
}

sub get_user ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $user_id = $self->param('id');
  unless ($self->stash('api_superuser')
          || $user_id == ($self->stash('api_user_id') // 0)) {
    return $self->render(
      json   => { error => 'Forbidden', message => 'Insufficient access' },
      status => 403
    );
  }

  my $user = eval { user_find($user_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $user);
}

1;
