package SauronAPI::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Net::Netmask;
use Sauron::BackEnd ();
use Sauron::Util ();
use JSON::PP ();

sub _check_trusted_ip($remote_ip, $trusted_ips) {
  for my $entry (@$trusted_ips) {
    return 1 if $entry eq $remote_ip;
    if ($entry =~ m{^([\d.:a-fA-F]+)/(\d+)$}) {
      my ($net, $bits) = ($1, $2);
      my $block;
      eval { $block = Net::Netmask->new("$net/$bits"); };
      return 1 if $block && $block->match($remote_ip);
    }
  }
  return 0;
}

# TODO: Check if needed
# not used right now, but could be useful for helpers
sub _load_user_context {
  my ($c, $user_id, $auth_method) = @_;
  my %perms;
  Sauron::BackEnd::get_permissions($user_id, \%perms);
  $c->stash(
    api_user_id     => $user_id,
    api_perms       => \%perms,
    api_auth_method => $auth_method,
  );
  return 1;
}

sub _render_user_response {
  my ($c, $user_id, $username, $auth_method) = @_;
  my %perms;
  Sauron::BackEnd::get_permissions($user_id, \%perms);
  my %user;
  my $email = '';
  my $name = '';
  my $superuser = 0;

  if (Sauron::BackEnd::get_user($username, \%user) == 0) {
    $email = $user{email} // '';
    $name = $user{name} // '';
    $superuser = $user{superuser} ? 1 : 0;
  }

  $c->render(json => {
    user => {
      id          => $user_id,
      username    => $username,
      name        => $name,
      email       => $email,
      superuser   => $superuser ? JSON::PP::true : JSON::PP::false,
      alevel      => $perms{alevel} // 0,
      auth_method => $auth_method,
    }
  });
}

# POST /auth/login
# Authenticate with email + password, create session.
sub login ($self) {
  my $json = $self->req->json;
  unless ($json && $json->{email} && $json->{password}) {
    return $self->render(
      json   => { error => 'Bad Request', message => 'email and password are required' },
      status => 400
    );
  }

  my $email    = $json->{email};
  my $password = $json->{password};

  unless ($email =~ /^[^\s@]+@[^\s@]+\.[^\s@]+$/) {
    return $self->render(
      json   => { error => 'Bad Request', message => 'Invalid email format' },
      status => 400
    );
  }

  my %user;
  if (Sauron::BackEnd::get_user_by_email($email, \%user) != 0) {
    return $self->render(
      json   => { error => 'Unauthorized', message => 'Invalid email or password' },
      status => 401
    );
  }

  my $status = Sauron::BackEnd::get_user_status($user{id});
  if ($status =~ /E/) {
    return $self->render(
      json   => { error => 'Forbidden', message => 'Account has expired' },
      status => 403
    );
  }
  if ($status =~ /L/) {
    return $self->render(
      json   => { error => 'Forbidden', message => 'Account is locked' },
      status => 403
    );
  }

  my $pwd_result = Sauron::Util::pwd_check($password, $user{password});
  if ($pwd_result != 0) {
    return $self->render(
      json   => { error => 'Unauthorized', message => 'Invalid email or password' },
      status => 401
    );
  }

  my $ip  = $self->req->env->{REMOTE_ADDR} // '';
  my $ttl = $self->app->config->{session}->{ttl} // 86400;
  my $token = Sauron::BackEnd::create_session($user{id}, 'password', $ip, $ttl);

  if (!$token) {
    return $self->render(
      json   => { error => 'Internal Server Error', message => 'Failed to create session' },
      status => 500
    );
  }

  my $cookie_name = $self->app->config->{session}->{cookie_name} // 'bff_session';
  my $secure      = $self->app->config->{session}->{secure} // 0;

  $self->cookie($cookie_name => $token, {
    path     => '/',
    http_only => 1,
    secure   => $secure,
    same_site => 'Lax',
    max_age  => $ttl,
  });

  _load_user_context($self, $user{id}, 'password');
  _render_user_response($self, $user{id}, $user{username}, 'password');
}

# POST /auth/logout
# Destroy session.
sub logout ($self) {
  my $cookie_name = $self->app->config->{session}->{cookie_name} // 'bff_session';
  my $token = $self->cookie($cookie_name);

  if ($token) {
    Sauron::BackEnd::delete_session($token);
  }

  $self->cookie($cookie_name => '', {
    path     => '/',
    http_only => 1,
    expires  => 1,
  });

  $self->render(json => { message => 'Logged out' });
}

# GET /auth/me
# Return current authenticated user info.
# Checks proxy auth header first (from reverse proxy OIDC),
# then falls back to bff_session cookie.
sub me ($self) {
  my $proxy = $self->app->config->{proxy_auth} // {};
  my $header = $proxy->{header} // 'X-Remote-User';
  my $match  = $proxy->{match}  // 'email';
  my @trusted = @{$proxy->{trusted_ips} // ['127.0.0.1', '::1']};

  my $remote_ip = $self->tx->remote_address;
  my $remote_user = $self->req->headers->header($header);

  if ($remote_user && _check_trusted_ip($remote_ip, \@trusted)) {
    my %user;
    my $found;
    if ($match eq 'email') {
      $found = (Sauron::BackEnd::get_user_by_email($remote_user, \%user) == 0);
    }
    else {
      $found = (Sauron::BackEnd::get_user($remote_user, \%user) == 0);
    }

    if ($found) {
      my $status = Sauron::BackEnd::get_user_status($user{id});
      if (!defined $status || $status =~ /[EL]/) {
        return $self->render(
          json   => { error => 'Forbidden', message => 'Account is no longer active' },
          status => 403
        );
      }
      _load_user_context($self, $user{id}, 'proxy');
      _render_user_response($self, $user{id}, $user{username}, 'proxy');
      return;
    }
  }

  my $cookie_name = $self->app->config->{session}->{cookie_name} // 'bff_session';
  my $token = $self->cookie($cookie_name);

  unless ($token) {
    return $self->render(
      json   => { error => 'Unauthorized', message => 'Not authenticated' },
      status => 401
    );
  }

  my $user_id = Sauron::BackEnd::verify_session($token);
  unless ($user_id) {
    return $self->render(
      json   => { error => 'Unauthorized', message => 'Session expired or invalid' },
      status => 401
    );
  }

  my %user;
  my $username;
  if (Sauron::BackEnd::get_user_by_id($user_id, \%user) == 0) {
    $username = $user{username};
  } else {
    return $self->render(
      json   => { error => 'Unauthorized', message => 'User not found' },
      status => 401
    );
  }

  my $status = Sauron::BackEnd::get_user_status($user_id);
  if (!defined $status || $status =~ /[EL]/) {
    Sauron::BackEnd::delete_session($token);
    return $self->render(
      json   => { error => 'Forbidden', message => 'Account is no longer active' },
      status => 403
    );
  }

  _load_user_context($self, $user_id, 'password');
  _render_user_response($self, $user_id, $username, 'password');
}

# GET /auth/proxy-login
# Entry point for proxy-authenticated users.
# Apache sets X-Remote-User after OIDC authentication.
# This endpoint returns user info if the header is valid.
sub proxy_login ($self) {
  my $proxy = $self->app->config->{proxy_auth} // {};
  my $header = $proxy->{header} // 'X-Remote-User';
  my $match  = $proxy->{match}  // 'email';
  my @trusted = @{$proxy->{trusted_ips} // ['127.0.0.1', '::1']};

  my $remote_ip = $self->tx->remote_address;
  my $remote_user = $self->req->headers->header($header);

  unless ($remote_user) {
    return $self->render(
      json   => { error => 'Unauthorized', message => 'No proxy auth header' },
      status => 401
    );
  }

  unless (_check_trusted_ip($remote_ip, \@trusted)) {
    return $self->render(
      json   => { error => 'Unauthorized', message => 'Untrusted proxy' },
      status => 401
    );
  }

  my %user;
  my $found;
  if ($match eq 'email') {
    $found = (Sauron::BackEnd::get_user_by_email($remote_user, \%user) == 0);
  }
  else {
    $found = (Sauron::BackEnd::get_user($remote_user, \%user) == 0);
  }

  unless ($found) {
    return $self->render(
      json   => { error => 'Unauthorized', message => 'User not found in system' },
      status => 401
    );
  }

  my $status = Sauron::BackEnd::get_user_status($user{id});
  if (!defined $status || $status =~ /[EL]/) {
    return $self->render(
      json   => { error => 'Forbidden', message => 'Account is no longer active' },
      status => 403
    );
  }

  _load_user_context($self, $user{id}, 'proxy');
  _render_user_response($self, $user{id}, $user{username}, 'proxy');
}

1;
