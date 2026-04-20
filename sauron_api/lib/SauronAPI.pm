package SauronAPI;

use Mojo::Base 'Mojolicious', -signatures;
use FindBin;
use lib "$FindBin::Bin/../.."; # Path to Sauron legacy modules

# Sauron Core Integration
use Sauron::Sauron;
use Sauron::DB;
use Sauron::BackEnd;
use Net::Netmask;

# This method will run once at server start
sub startup {
  my $self = shift;

  # Load configuration from Mojolicious config file
  my $config = $self->plugin('NotYAMLConfig');
  $self->secrets($config->{secrets});

  # Fix request base URL when behind a reverse proxy
  # so that OpenAPI spec and redirects use the correct scheme/host
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
    if ($remote_user) {
      my $result = $c->resolve_proxy_user;
      if ($result->{user_id}) {
        $c->load_user_context($result->{user_id}, 'proxy');
      }
      return; # proxy header present — don't check session cookie
    }

    # Session cookie auth (browser login)
    # Only runs if no proxy auth header
    my $result = $c->resolve_session_user;
    if ($result->{user_id}) {
      $c->load_user_context($result->{user_id}, 'password');
    }
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
      $superuser = $user{superuser} ? 1 : 0;
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
    unless ($c->stash('api_user_id')) {
      $c->render(json => { error => 'Unauthorized', message => 'Not authenticated' }, status => 401);
      return 0;
    }
    return 1;
  });

  $self->helper(resolve_proxy_user => sub ($c) {
    my $proxy = $config->{proxy_auth} // {};
    my $header = $proxy->{header} // 'X-Remote-User';
    my $match  = $proxy->{match}  // 'email';
    my @trusted = @{$proxy->{trusted_ips} // ['127.0.0.1', '::1']};

    my $remote_ip = $c->tx->remote_address;
    my $remote_user = $c->req->headers->header($header);

    return { error => 'Unauthorized', message => 'No proxy auth header', status => 401 } unless $remote_user;

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
    return { error => 'Unauthorized', message => 'Untrusted proxy', status => 401 } unless $trusted;

    my %user;
    my $found;
    if ($match eq 'email') {
      $found = (Sauron::BackEnd::get_user_by_email($remote_user, \%user) == 0);
    } else {
      $found = (Sauron::BackEnd::get_user($remote_user, \%user) == 0);
    }
    return { error => 'Unauthorized', message => "User '$remote_user' not found", status => 401 } unless $found;

    my $ustatus = Sauron::BackEnd::get_user_status($user{id});
    return { error => 'Forbidden', message => 'Account is no longer active', status => 403 } if (!defined $ustatus || $ustatus =~ /[EL]/);

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
    url => $self->home->child('public', 'api', 'openapi.yaml'),
    route => $self->routes->any('/api/v1'),
    schema => 'v3',
    skip_validating_specification => 1,
    security => {
      BearerAuth => sub ($c, $definition, $scopes, $cb) {
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

  # Root route - serve static index.html
  $self->routes->get('/')->to('Root#index');

  # Helpers
  $self->helper(get_server_id_or_404 => sub ($c, $name) {
    my $id = Sauron::BackEnd::get_server_id($name);
    return $id if $id > 0;

    $c->render(
      openapi => {
        error   => 'Not Found',
        message => "Server '$name' not found"
      },
      status  => 404
    );
    return undef;
  });
}

1;
