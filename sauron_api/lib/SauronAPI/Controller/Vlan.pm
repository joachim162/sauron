package SauronAPI::Controller::Vlan;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::Sauron ();
use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Repository::Vlan qw(vlan_list vlan_find vlan_create vlan_update vlan_delete);

# Reads require server R + ALEVEL_VLANS; writes require superuser (legacy CGI
# parity, Sauron/CGI/Nets.pm).

# GET /servers/{server}/vlans
sub list_vlans ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  return unless check_perms($self, type => 'level', level => $main::ALEVEL_VLANS);

  my $page     = $self->param('page')     // 1;
  my $per_page = $self->param('per_page') // 50;

  my ($vlans, $meta) = eval {
    vlan_list($server_id,
      page => $page, per_page => $per_page,
      $self->list_query_params);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $vlans, metadata => $meta });
}

# GET /servers/{server}/vlans/{vlan}
sub get_vlan ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  return unless check_perms($self, type => 'level', level => $main::ALEVEL_VLANS);
  my $vlan_id = $self->get_vlan_id_or_404($server_id, $self->param('vlan')) or return;

  my $vlan = eval { vlan_find($server_id, $vlan_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $vlan);
}

# POST /servers/{server}/vlans
sub create_vlan ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');

  my $vlan = eval { vlan_create($server_id, $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $vlan, status => 201);
}

# PUT /servers/{server}/vlans/{vlan}
sub update_vlan ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');
  my $vlan_id = $self->get_vlan_id_or_404($server_id, $self->param('vlan')) or return;

  my $vlan = eval { vlan_update($server_id, $vlan_id, $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $vlan);
}

# DELETE /servers/{server}/vlans/{vlan}
sub delete_vlan ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');
  my $vlan_id = $self->get_vlan_id_or_404($server_id, $self->param('vlan')) or return;

  eval { vlan_delete($vlan_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

1;
