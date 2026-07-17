package SauronAPI::Controller::Host;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use SauronAPI::AuthZ qw(check_perms);
use SauronAPI::Exception            ();
use SauronAPI::Exception::NotFound;
use SauronAPI::Exception::Conflict;
use SauronAPI::Exception::Validation;
use SauronAPI::Exception::Persistence;
use SauronAPI::Repository::Host qw(
  host_list host_find host_create host_update host_delete
);

# Render a typed exception as an OpenAPI-shaped error response.
sub _render_exception {
  my ($self, $e) = @_;
  $self->render(
    openapi => { error => $e->kind, message => "$e" },
    status  => $e->http_status,
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

  my $server_name = $self->param("server");
  my $zone_name   = $self->param("zone");

  my $page     = $self->param("page")     // 1;
  my $per_page = $self->param("per_page") // 50;

  # Authz: read access on zone. We do not have zone_id until the repo resolves
  # server/zone, so we still need to resolve server/zone here for the perm check.
  my $server_id = _server_id_or_render($self, $server_name) or return;
  my $zone_id   = _zone_id_or_render($self, $zone_name)   or return;
  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'R');

  my ($data, $meta) = eval { host_list($server_name, $zone_name, page => $page, per_page => $per_page) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => { data => $data, metadata => $meta });
}

sub get_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_name = $self->param("server");
  my $zone_name   = $self->param("zone");
  my $hostname    = $self->param("hostname");

  my $server_id = _server_id_or_render($self, $server_name) or return;
  my $zone_id   = _zone_id_or_render($self, $zone_name)   or return;
  return unless check_perms($self, type => 'zone', zone_id => $zone_id, server_id => $server_id, rule => 'R');

  my $host = eval { host_find($server_name, $zone_name, $hostname) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => $host);
}

sub add_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_name = $self->param("server");
  my $zone_name   = $self->param("zone");

  my $server_id = _server_id_or_render($self, $server_name) or return;
  my $zone_id   = _zone_id_or_render($self, $zone_name)   or return;
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
    SauronAPI::Exception::Permission->throw(
      message => "Permission denied for IP '$ip'"
    );
  };

  my $host = eval { host_create($server_name, $zone_name, $json, on_ip => $ip_allowed) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => $host, status => 201);
}

sub delete_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_name = $self->param("server");
  my $zone_name   = $self->param("zone");
  my $hostname    = $self->param("hostname");

  my $server_id = _server_id_or_render($self, $server_name) or return;
  my $zone_id   = _zone_id_or_render($self, $zone_name)   or return;
  return unless check_perms($self, type => 'delhost', hostname => $hostname, zone_id => $zone_id, server_id => $server_id);

  eval { host_delete($server_name, $zone_name, $hostname) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => undef, status => 204);
}

sub update_host ($self) {
  return unless $self->openapi->valid_input;
  return unless $self->require_auth;

  my $server_name = $self->param("server");
  my $zone_name   = $self->param("zone");
  my $hostname    = $self->param("hostname");
  my $json        = $self->req->json;

  my $server_id = _server_id_or_render($self, $server_name) or return;
  my $zone_id   = _zone_id_or_render($self, $zone_name)   or return;
  return unless check_perms($self, type => 'host', hostname => $hostname, zone_id => $zone_id, server_id => $server_id);

  if (my $missing = _check_rhf($self, $json, 0)) {
    return $self->render(
      openapi => { error => 'Bad Request', message => 'Required fields missing: ' . join(', ', @$missing) },
      status  => 400
    );
  }

  my $host = eval { host_update($server_name, $zone_name, $hostname, $json) };
  return $self->_render_exception($@) if $@;

  $self->render(openapi => $host);
}

# --- Resolution helpers used only for authz (no DB writes) ---

sub _server_id_or_render {
  my ($self, $name) = @_;
  my $id = Sauron::BackEnd::get_server_id($name);
  if ($id <= 0) {
    $self->render(
      openapi => { error => 'Not Found', message => "Server '$name' not found" },
      status  => 404
    );
    return undef;
  }
  return $id;
}

sub _zone_id_or_render {
  my ($self, $name) = @_;
  my $id = Sauron::BackEnd::get_zone_id_by_name($name);
  if ($id <= 0) {
    $self->render(
      openapi => { error => 'Not Found', message => "Zone '$name' not found" },
      status  => 404
    );
    return undef;
  }
  return $id;
}

1;
