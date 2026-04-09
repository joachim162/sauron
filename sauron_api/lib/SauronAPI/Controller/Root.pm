package SauronAPI::Controller::Root;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::File qw(path);

sub index ($self) {
  my $file = $self->app->home->child('public', 'index.html');
  $self->render(data => $file->slurp, format => 'html');
}

1;
