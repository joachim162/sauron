package SauronAPI::Controller::Net;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::Sauron ();
use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Repository::Net qw(net_list net_find net_create net_update net_delete);

sub list_nets ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');

  my $perms = $self->stash('api_perms');
  my $user_alevel = $perms->{alevel} // 0;

  # Unallocated address blocks are only shown to sufficiently
  # authorized users (same gating as the legacy CGI menu entry);
  # below that level the free list mode silently behaves like all.
  my $list = $self->param('list') // 'all';
  if ($list eq 'free') {
    $list = 'all' unless ($self->stash('api_superuser')
                          || ($user_alevel >= $main::ALEVEL_SHOW_UNALLOCATED_CIDRS));
  }

  my $include_vlan_names = ($self->stash('api_superuser')
                            || ($user_alevel >= $main::ALEVEL_VLANS)) ? 1 : 0;

  my $page     = $self->param('page')     // 1;
  my $per_page = $self->param('per_page') // 50;

  my ($nets, $meta) = eval {
    net_list($server_id,
             list => $list,
             alevel => $user_alevel,
             include_vlan_names => $include_vlan_names,
             page => $page, per_page => $per_page);
  };
  return $self->render_exception($@) if $@;

  $self->render(openapi => { data => $nets, metadata => $meta });
}

sub list_assignable_subnets ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');

  my $perms = $self->stash('api_perms');
  my $user_alevel = $perms->{alevel} // 0;
  my $is_superuser = $self->stash('api_superuser');

  my $include_vlan_names = ($is_superuser
                            || ($user_alevel >= $main::ALEVEL_VLANS)) ? 1 : 0;

  my $subnets = eval {
    net_list($server_id,
             subnets => 1,
             alevel => $user_alevel,
             include_vlan_names => $include_vlan_names);
  };
  return $self->render_exception($@) if $@;

  my %net_perms = %{$perms->{net} // {}};
  my $has_net_restrictions = !$is_superuser && keys %net_perms > 0;
  if ($has_net_restrictions) {
    @$subnets = grep { $net_perms{$_->{id}} } @$subnets;
  }

  $self->render(openapi => $subnets);
}

sub get_net ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'server', server_id => $server_id, rule => 'R');
  my $net_id = $self->get_net_id_or_404($server_id, $self->param('net')) or return;

  my $perms = $self->stash('api_perms');
  my $user_alevel = $perms->{alevel} // 0;
  my $include_vlan_names = ($self->stash('api_superuser')
                            || ($user_alevel >= $main::ALEVEL_VLANS)) ? 1 : 0;

  my $net = eval { net_find($net_id, server_id => $server_id, include_vlan_names => $include_vlan_names) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $net);
}

sub add_net ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');

  my $net = eval { net_create($server_id, $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $net, status => 201);
}

sub update_net ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');
  my $net_id = $self->get_net_id_or_404($server_id, $self->param('net')) or return;

  my $net = eval { net_update($net_id, $self->req->json // {}) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => $net);
}

sub delete_net ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param('server')) or return;
  return unless check_perms($self, type => 'superuser');
  my $net_id = $self->get_net_id_or_404($server_id, $self->param('net')) or return;

  eval { net_delete($net_id) };
  return $self->render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

1;
