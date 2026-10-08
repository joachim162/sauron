package SauronAPI;

use Mojo::Base 'Mojolicious', -signatures;
use FindBin;
use Scalar::Util ();
use lib "$FindBin::Bin/../.."; # Path to Sauron legacy modules

# Sauron Core Integration
use Sauron::Sauron;
use Sauron::DB;
use Sauron::BackEnd;
use SauronAPI::Repository::Net ();
use SauronAPI::Exception ();
use Net::Netmask;

# This method will run once at server start
sub startup {
  my $self = shift;

  # Load configuration from Mojolicious config file
  my $config = $self->plugin('NotYAMLConfig');
  $self->secrets($config->{secrets});

  # Fix request base URL when behind a reverse proxy
  # so that OpenAPI spec and redirects use the correct scheme/host
  # TODO: Check if this is Docker only problem
  # or if it can be handled by Apache
  $self->hook(before_dispatch => sub ($c) {
    my $proto = $c->req->headers->header('X-Forwarded-Proto');
    my $host  = $c->req->headers->header('X-Forwarded-Host') // $c->req->headers->header('Host');
    my $port  = $c->req->headers->header('X-Forwarded-Port');
    if ($proto) {
      $c->req->url->base->scheme($proto);
    }
    if ($host) {
      $host =~ s/:[0-9]+$//; # strip port
      $c->req->url->base->host($host);
    }
    if ($port && $port ne '80' && $port ne '443') {
      $c->req->url->base->port($port);
    } else {
      $c->req->url->base->port(undef);
    }

    # Proxy auth: trusted reverse proxy sets X-Remote-User after OIDC
    # Runs first — takes priority over session cookie
    my $proxy_cfg = $config->{proxy_auth} // {};
    my $header = $proxy_cfg->{header} // 'X-Remote-User';
    my $remote_user = $c->req->headers->header($header);
    if (defined $remote_user && length $remote_user) {
      my $result = $c->resolve_proxy_user;
      $c->load_user_context($result->{user_id}, 'proxy');
      return; # proxy header present — don't check session cookie
    }

    # Session cookie auth (browser login)
    # Only runs if no proxy auth header
    my $result = $c->resolve_session_user;
    if ($result->{user_id}) {
      $c->load_user_context($result->{user_id}, 'password');
    }
  });

  # Global exception boundary: any SauronAPI::Exception that unwinds out of an
  # action or helper is rendered through the shared render_exception helper.
  $self->hook(around_dispatch => sub ($next, $c) {
    my $err;
    eval { $next->(); 1 } or $err = $@;
    return $c->render_exception($err) if $err;
  });

  if ($ENV{PROXY_AUTH_TRUSTED_IPS}) {
    my @ips = split(/,/, $ENV{PROXY_AUTH_TRUSTED_IPS});
    $config->{proxy_auth} //= {};
    $config->{proxy_auth}{trusted_ips} = \@ips;
  }

  load_config();
  db_connect();

  $self->helper(load_user_context => sub ($c, $user_id, $auth_method) {
    my %perms;
    Sauron::BackEnd::get_permissions($user_id, \%perms);
    my %user;
    my $superuser = 0;
    if (Sauron::BackEnd::get_user_by_id($user_id, \%user) == 0) {
      $superuser = ($user{superuser} && $user{superuser} eq 't') ? 1 : 0;
      Sauron::BackEnd::set_muser($user{username});
    }
    $c->stash(
      api_user_id     => $user_id,
      api_perms       => \%perms,
      api_auth_method => $auth_method,
      api_superuser   => $superuser,
    );
    return 1;
  });

  $self->helper(require_auth => sub ($c) {
    SauronAPI::Exception->unauthorized('Not authenticated') unless $c->stash('api_user_id');
    return 1;
  });

  # TODO: Test
  $self->helper(resolve_proxy_user => sub ($c) {
    my $proxy = $config->{proxy_auth} // {};
    my $header = $proxy->{header} // 'X-Remote-User';
    my $match  = $proxy->{match}  // 'email';
    my @trusted = @{$proxy->{trusted_ips} // ['127.0.0.1', '::1']};

    my $remote_ip = $c->tx->remote_address;
    my $remote_user = $c->req->headers->header($header);

    warn "DEBUG resolve_proxy_user: remote_ip=$remote_ip header=" . ($remote_user // 'undef') . "\n";

    SauronAPI::Exception->unauthorized('No proxy auth header') unless defined $remote_user && length $remote_user;

    my $trusted = 0;
    for my $entry (@trusted) {
      if ($entry eq $remote_ip) {
        $trusted = 1;
        last;
      }
      if ($entry =~ m{^([\d.:a-fA-F]+)/(\d+)$}) {
        my ($net, $bits) = ($1, $2);
        my $block;
        eval { $block = Net::Netmask->new("$net/$bits"); };
        if ($block && $block->match($remote_ip)) {
          $trusted = 1;
          last;
        }
      }
    }
    warn "DEBUG resolve_proxy_user: trusted=$trusted trusted_ips=" . join(',', @trusted) . "\n";
    SauronAPI::Exception->unauthorized('Untrusted proxy') unless $trusted;

    my %user;
    my $found;
    if ($match eq 'email') {
      $found = (Sauron::BackEnd::get_user_by_email($remote_user, \%user) == 0);
    } else {
      $found = (Sauron::BackEnd::get_user($remote_user, \%user) == 0);
    }
    warn "DEBUG resolve_proxy_user: match=$match found=$found user=" . ($user{id} // 'none') . "\n";
    SauronAPI::Exception->unauthorized("User '$remote_user' not found") unless $found;

    my $ustatus = Sauron::BackEnd::get_user_status($user{id});
    warn "DEBUG resolve_proxy_user: ustatus=" . ($ustatus // 'undef') . "\n";
    SauronAPI::Exception->forbidden('Account is no longer active') if (!defined $ustatus || $ustatus =~ /[EL]/);

    return { user_id => $user{id}, username => $user{username} };
  });

  $self->helper(resolve_session_user => sub ($c) {
    my $cookie_name = $config->{session}{cookie_name} // 'bff_session';
    my $token = $c->cookie($cookie_name);

    return { error => 'Unauthorized', message => 'Not authenticated', status => 401 } unless $token;

    my $user_id = Sauron::BackEnd::verify_session($token);
    return { error => 'Unauthorized', message => 'Session expired or invalid', status => 401 } unless $user_id;

    my %user;
    if (Sauron::BackEnd::get_user_by_id($user_id, \%user) != 0) {
      return { error => 'Unauthorized', message => 'User not found', status => 401 };
    }

    my $ustatus = Sauron::BackEnd::get_user_status($user_id);
    if (!defined $ustatus || $ustatus =~ /[EL]/) {
      Sauron::BackEnd::delete_session($token);
      return { error => 'Forbidden', message => 'Account is no longer active', status => 403 };
    }

    return { user_id => $user_id, username => $user{username} };
  });

  # OpenAPI Plugin Setup
  $self->plugin(OpenAPI => {
    url => $self->home->child('public', 'api', 'dist', 'openapi.yaml'),
    route => $self->routes->any('/api/v1'),
    schema => 'v3',
    skip_validating_specification => 1,
    security => {
      BearerAuth => sub ($c, $definition, $scopes, $cb) {
        if ($c->stash('api_user_id')) {
          return $c->$cb();
        }

        my $auth = $c->req->headers->authorization;
        return $c->$cb('Authorization header not present') unless ($auth);

        my ($token) = $auth =~ /^Bearer\s+(.+)$/;
        return $c->$cb('Invalid Authorization format') unless ($token);

        my $user_id = Sauron::BackEnd::verify_pat($token);
        return $c->$cb('Invalid or expired token') unless ($user_id);

        $c->load_user_context($user_id, 'pat');
        return $c->$cb();
      },
    }
  });

  $self->plugin(SwaggerUI => {
    route => $self->routes()->any('api'),
    url => "/api/v1",
    title => "Sauron API Documentation"
  });

  # Root route - redirect to frontend
  $self->routes->get('/')->to(cb => sub ($c) { $c->redirect_to('/app/') });

  # Helpers
  $self->helper(list_query_params => sub ($c) {
    return (
      params => $c->req->query_params->to_hash,
      sort   => scalar $c->param('sort'),
    );
  });

  $self->helper(get_server_id_or_404 => sub ($c, $name) {
    my $id = Sauron::BackEnd::get_server_id($name);
    return $id if $id > 0;

    SauronAPI::Exception->not_found("Server '$name' not found");
  });

  $self->helper(get_zone_id_or_404 => sub ($c, $server_id, $name) {
    my $id = Sauron::BackEnd::get_zone_id($name, $server_id);
    return $id if $id > 0;

    SauronAPI::Exception->not_found("Zone '$name' not found");
  });

  $self->helper(get_net_id_or_404 => sub ($c, $server_id, $param) {
    my $id = SauronAPI::Repository::Net::net_id_for($server_id, $param);
    return $id if $id > 0;

    SauronAPI::Exception->not_found("Network '$param' not found on this server");
  });

  $self->helper(get_group_id_or_404 => sub ($c, $server_id, $name) {
    my $id = Sauron::BackEnd::get_group_by_name($server_id, $name);
    return $id if $id > 0;

    SauronAPI::Exception->not_found("Group '$name' not found on this server");
  });

  $self->helper(get_acl_id_or_404 => sub ($c, $server_id, $name) {
    my $id = Sauron::BackEnd::get_acl_by_name($server_id, $name);
    return $id if $id > 0;

    SauronAPI::Exception->not_found("ACL '$name' not found on this server");
  });

  $self->helper(get_vlan_id_or_404 => sub ($c, $server_id, $name) {
    my $id = Sauron::BackEnd::get_vlan_by_name($server_id, $name);
    return $id if $id > 0;

    SauronAPI::Exception->not_found("VLAN '$name' not found on this server");
  });

  # Render a SauronAPI::Exception as an OpenAPI-shaped error response.
  # Non-Exception dies (e.g. DBD::Pg) become a generic 500.
  $self->helper(render_exception => sub ($c, $e) {
    my ($status, $kind, $message) =
      Scalar::Util::blessed($e) && $e->isa('SauronAPI::Exception')
      ? ($e->status, $e->kind, $e->message)
      : (500, 'Internal Server Error', 'An unexpected error occurred');
    # TODO: log non-Exception $e via a proper logging framework once one is in place

    # Exceptions raised before routing (e.g. in before_dispatch) have no
    # OpenAPI operation to render against, so fall back to plain JSON.
    return if $c->render_maybe(openapi => { error => $kind, message => $message }, status => $status);

    $c->render(json => { error => $kind, message => $message }, status => $status);
  });
}

1;
