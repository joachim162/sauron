package SauronAPI::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Sauron::BackEnd ();
use Sauron::Util ();
use JSON::PP ();

sub _render_user_response {
  my ($c, $user_id, $username, $auth_method) = @_;
  my %perms;
  Sauron::BackEnd::get_permissions($user_id, \%perms);
  $c->stash(
    api_user_id     => $user_id,
    api_perms       => \%perms,
    api_auth_method => $auth_method,
  );
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
# If called through OpenAPI security (BearerAuth/CookieAuth), the user
# context is already stashed. Otherwise, check proxy header and session cookie.
sub me ($self) {
  if (my $uid = $self->stash('api_user_id')) {
    my $method = $self->stash('api_auth_method') // 'pat';
    my %user;
    if (Sauron::BackEnd::get_user_by_id($uid, \%user) == 0) {
      _render_user_response($self, $uid, $user{username}, $method);
      return;
    }
  }

  my $proxy = $self->app->config->{proxy_auth} // {};
  my $header = $proxy->{header} // 'X-Remote-User';
  if ($self->req->headers->header($header)) {
    my $result = $self->resolve_proxy_user;
    if ($result->{user_id}) {
      _render_user_response($self, $result->{user_id}, $result->{username}, 'proxy');
      return;
    }
    if ($result->{status} == 403) {
      return $self->render(
        json   => { error => $result->{error}, message => $result->{message} },
        status => $result->{status}
      );
    }
  }

  my $result = $self->resolve_session_user;
  if ($result->{user_id}) {
    _render_user_response($self, $result->{user_id}, $result->{username}, 'password');
    return;
  }

  $self->render(
    json   => { error => 'Unauthorized', message => 'Not authenticated' },
    status => 401
  );
}

# GET /auth/proxy-login
# Entry point for proxy-authenticated users.
# Apache sets X-Remote-User after OIDC authentication.
# This endpoint returns user info if the header is valid.
sub proxy_login ($self) {
  my $result = $self->resolve_proxy_user;
  if ($result->{error}) {
    return $self->render(
      json   => { error => $result->{error}, message => $result->{message} },
      status => $result->{status}
    );
  }
  _render_user_response($self, $result->{user_id}, $result->{username}, 'proxy');
}

1;
