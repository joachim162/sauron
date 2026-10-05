package SauronAPI::Controller::Key;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::Sauron ();
use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Repository::Key qw(key_list);

# Read-only TSIG key reference data for pickers (ADR 0011): server R +
# ALEVEL_ACLS, exactly the legacy browse_keys gate. Key lifecycle stays with
# the keygen CLI.

# GET /servers/{server}/keys
sub list_keys ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  return unless check_perms($self, type => 'level', level => $main::ALEVEL_ACLS);

  my $page     = $self->param('page')     // 1;
  my $per_page = $self->param('per_page') // 50;

  my ($keys, $meta) = eval {
    key_list($server_id,
      page => $page, per_page => $per_page,
      $self->list_query_params);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $keys, metadata => $meta });
}

1;
