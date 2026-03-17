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

  # OpenAPI Plugin Setup
  $self->plugin(OpenAPI => {
    url => $self->home->child('public', 'api', 'openapi.yaml'),
    route => $self->routes->any('/api/v1'),
    schema => 'v3',
    skip_validating_specification => 1,
    security => {
      ApiKeyAuth => sub ($c, $definition, $scopes, $cb) {
        my $provided_key = $c->req->headers->header('X-API-KEY');
        if ($provided_key && exists $config->{api_keys}->{$provided_key}) {
          my $key_data = $config->{api_keys}->{$provided_key};
          my $user_role = $key_data->{role};
          print "user role from config: '$user_role'\n";
          print "user role from HTTP: '@$scopes'\n";
          my $is_authorized = grep { $_ eq $user_role } @$scopes;
          return $c->$cb("Forbidden: You do not have permissions to perform this action") unless $is_authorized;
          $c->stash(
            api_user => $key_data->{owner},
            api_role => $key_data->{role}
          );

          return $c->$cb();
        }
        return $c->$cb("Invalid or missing API key");
      }
    }
  });

  $self->plugin(SwaggerUI => {
    route => $self->routes()->any('api'),
    url => "/api/v1",
    title => "Sauron API Documentation"
  });

  # Router
  my $r = $self->routes;

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
