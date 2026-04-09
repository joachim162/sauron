package SauronAPI;

use Mojo::Base 'Mojolicious', -signatures;
use FindBin;
use lib "$FindBin::Bin/../.."; # Path to Sauron legacy modules

# Sauron Core Integration
use Sauron::Sauron;
use Sauron::DB;
use Sauron::BackEnd;

# This method will run once at server start
sub startup {
  my $self = shift;

  # Load configuration from Mojolicious config file
  my $config = $self->plugin('NotYAMLConfig');
  $self->secrets($config->{secrets});

  load_config();
  db_connect();

  # Shared logic: load permissions and stash user context
  my $load_user_context = sub ($c, $user_id, $auth_method) {
    my %perms;
    Sauron::BackEnd::get_permissions($user_id, \%perms);
    $c->stash(
      api_user_id     => $user_id,
      api_perms       => \%perms,
      api_auth_method => $auth_method,
    );
    return 1;
  };

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

        $load_user_context->($c, $user_id, 'pat');
        return $c->$cb();
      },
      CookieAuth => sub ($c, $definition, $scopes, $cb) {
        my $cookie_name = $config->{session}->{cookie_name} // 'bff_session';
        my $token = $c->cookie($cookie_name);
        return $c->$cb('No session cookie') unless ($token);

        my $user_id = Sauron::BackEnd::verify_session($token);
        return $c->$cb('Invalid or expired session') unless ($user_id);

        my $status = Sauron::BackEnd::get_user_status($user_id);
        if (!defined $status || $status =~ /[EL]/) {
          Sauron::BackEnd::delete_session($token);
          return $c->$cb('Account is no longer active');
        }

        $load_user_context->($c, $user_id, 'session');
        return $c->$cb();
      },
    }
  });

  $self->plugin(SwaggerUI => {
    route => $self->routes()->any('api'),
    url => "/api/v1",
    title => "Sauron API Documentation"
  });

  # Router
  my $r = $self->routes;

  # Auth routes (outside OpenAPI - these handle login/logout, not resource CRUD)
  my $auth = $r->any('/auth')->to(controller => 'Auth');
  $auth->post('/login')->to(action => 'login');
  $auth->post('/logout')->to(action => 'logout');
  $auth->get('/me')->to(action => 'me');

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
