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
