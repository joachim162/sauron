package SauronAPI::Controller::Host;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Scalar::Util qw(blessed);

use Sauron::BackEnd ();
use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Exception ();
use SauronAPI::Repository::Host qw(
  host_list host_find host_create host_update host_delete host_copy host_move
);

# Render a typed exception as an OpenAPI-shaped error response.
# Non-Exception dies (e.g. DBD::Pg) become a generic 500.
sub _render_exception {
  my ($self, $e) = @_;

  if (blessed $e && $e->isa('SauronAPI::Exception')) {
    return $self->render(
      openapi => { error => $e->kind, message => $e->message },
      status  => $e->status,
    );
  }

  # TODO: log $e via a proper logging framework once one is in place
  $self->render(
    openapi => { error => 'Internal Server Error', message => 'An unexpected error occurred' },
    status  => 500,
  );
}

# Required Host Fields check. Repository does not depend on $c; the controller
# still owns RHF because it is an authz/perm concern.
sub _check_rhf {
  my ($c, $json, $is_create) = @_;

  return if $c->stash('api_superuser');

  my $rhf = $c->stash('api_perms')->{rhf} || {};
  return unless keys %$rhf;

  my @missing;
  for my $field (sort keys %$rhf) {
    next unless $rhf->{$field} == 0;
    my $val = $json->{$field};
    if ($is_create) {
      push @missing, $field unless defined $val && $val =~ /\S/;
    } else {
      next unless exists $json->{$field};
      push @missing, $field unless defined $val && $val =~ /\S/;
    }
  }
  return @missing ? \@missing : undef;
}

# --- CRUD subroutines ---

sub list_hosts ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $page     = $self->param("page")     // 1;
  my $per_page = $self->param("per_page") // 50;

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  my $zone_id   = $self->get_zone_id_or_404($server_id, $self->param("zone")) or return;
  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'R');

  my ($data, $meta) = eval { host_list($server_id, $zone_id, page => $page, per_page => $per_page) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => { data => $data, metadata => $meta });
}

sub get_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $hostname = $self->param("hostname");

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  my $zone_id   = $self->get_zone_id_or_404($server_id, $self->param("zone")) or return;
  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'R');

  my $host = eval { host_find($server_id, $zone_id, $hostname) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => $host);
}

sub add_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  my $zone_id   = $self->get_zone_id_or_404($server_id, $self->param("zone")) or return;
  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'RW');

  my $json = $self->req->json;
  $json->{hostname} //= $json->{domain};
  unless ($json->{hostname}) {
    return $self->render(
      openapi => { error => 'Bad Request', message => "'hostname' is required in request body" },
      status  => 400
    );
  }

  if (my $missing = _check_rhf($self, $json, 1)) {
    return $self->render(
      openapi => { error => 'Bad Request', message => 'Required fields missing: ' . join(', ', @$missing) },
      status  => 400
    );
  }

  my $ip_allowed = sub {
    my ($ip) = @_;
    return 1 if check_perms($self, type => 'ip', rule => $ip);
    SauronAPI::Exception->forbidden("Permission denied for IP '$ip'");
  };

  my $host = eval { host_create($server_id, $zone_id, $json, on_ip => $ip_allowed) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => $host, status => 201);
}

sub copy_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $source_hostname = $self->param("hostname");
  my $json = $self->req->json // {};

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  my $zone_id   = $self->get_zone_id_or_404($server_id, $self->param("zone")) or return;
  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'RW');

  my $ip_allowed = sub {
    my ($ip) = @_;
    return 1 if check_perms($self, type => 'ip', rule => $ip);
    SauronAPI::Exception->forbidden("Permission denied for IP '$ip'");
  };

  # RHF check on the merged record (source fields + overrides).
  my $check_rhf = sub {
    my ($merged) = @_;
    if (my $missing = _check_rhf($self, $merged, 1)) {
      SauronAPI::Exception->validation(
        'Required fields missing: ' . join(', ', @$missing)
      );
    }
  };

  my $host = eval { host_copy($server_id, $zone_id, $source_hostname, $json,
                               on_ip => $ip_allowed, on_merged => $check_rhf) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => $host, status => 201);
}

sub move_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $hostname = $self->param("hostname");
  my $json     = $self->req->json;

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  my $zone_id   = $self->get_zone_id_or_404($server_id, $self->param("zone")) or return;

  # Source host permission (both modes)
  return unless check_perms($self, type => 'host', hostname => $hostname, zone_id => $zone_id, server_id => $server_id);

  # Zone move: check target zone RW and hostname mask
  if (exists $json->{zone}) {
    my $target_zone_id = Sauron::BackEnd::get_zone_id($json->{zone}, $server_id);
    if ($target_zone_id > 0) {
      return unless check_perms($self, type => 'zone', zone_id => $target_zone_id, server_id => $server_id, rule => 'RW');
      # Also check hostname mask in the target zone (matching CGI)
      return unless check_perms($self, type => 'host', hostname => $hostname, zone_id => $target_zone_id, server_id => $server_id);
    }
  }

  my $ip_allowed = sub {
    my ($ip) = @_;
    return 1 if check_perms($self, type => 'ip', rule => $ip);
    SauronAPI::Exception->forbidden("Permission denied for IP '$ip'");
  };

  my $host = eval { host_move($server_id, $zone_id, $hostname, $json, on_ip => $ip_allowed) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => $host);
}

sub delete_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $hostname = $self->param("hostname");

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  my $zone_id   = $self->get_zone_id_or_404($server_id, $self->param("zone")) or return;
  return unless check_perms($self, type => 'delhost', hostname => $hostname, zone_id => $zone_id, server_id => $server_id);

  eval { host_delete($server_id, $zone_id, $hostname) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

sub update_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $hostname = $self->param("hostname");
  my $json     = $self->req->json;

  my $server_id = $self->get_server_id_or_404($self->param("server")) or return;
  my $zone_id   = $self->get_zone_id_or_404($server_id, $self->param("zone")) or return;

  # Only a type transition needs the current host's type for authz; fetching
  # unconditionally would leak host existence (404 vs 403) to users without
  # permission and run get_host before authorization on every PUT.
  my $perm_type = 'host';
  if (exists $json->{type}) {
    my $current = eval { host_find($server_id, $zone_id, $hostname) };
    return $self->_render_exception($@) if $@;
    if ($json->{type} != $current->{type}) {
      if    ($current->{type} == 1 && $json->{type} == 101) { $perm_type = 'delhost'; }
      elsif ($current->{type} == 101 && $json->{type} == 1) { $perm_type = 'host'; }
    }
  }
  return unless check_perms($self, type => $perm_type, hostname => $hostname, zone_id => $zone_id, server_id => $server_id);

  if (my $missing = _check_rhf($self, $json, 0)) {
    return $self->render(
      openapi => { error => 'Bad Request', message => 'Required fields missing: ' . join(', ', @$missing) },
      status  => 400
    );
  }

  my $host = eval { host_update($server_id, $zone_id, $hostname, $json) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => $host);
}

1;
