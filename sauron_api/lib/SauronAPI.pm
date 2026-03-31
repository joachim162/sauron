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
      # security handler 'BearerAuth' has to match with the security schema defined in openapi.yaml
      BearerAuth => sub ($c, $definition, $scopes, $cb) {
        my $auth = $c->req->headers->authorization;
        print "Auth header value: '$auth'\n";
        return $c->$cb('Authorization header not present') unless $auth;

        my ($token) = $auth =~ /^Bearer\s+(.+)$/;
        print "Token value: '$token'\n";
        return $c->$cb('Invalid Authorization format') unless $token;

        my $user_id = Sauron::BackEnd::verify_pat($token);
        return $c->$cb('Invalid or expired token') unless $user_id;

        my %perms;
        Sauron::BackEnd::get_permissions($user_id, \%perms);

        $c->stash(
          api_user_id => $user_id,
          api_perms   => \%perms,
        );

        return $c->$cb();
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
