package SauronAPI::Exception;
use strict;
use warnings;

use Mojo::Base -base;
use overload '""' => sub { shift->stringify }, fallback => 1;

has 'message' => '';

sub new {
  my ($class, %args) = @_;
  my $self = $class->SUPER::new(message => $args{message} // '');
  $self->{_context} = $args{context} if defined $args{context};
  return $self;
}

sub stringify { shift->message }

sub context { shift->{_context} }

sub throw {
  my ($class, %args) = @_;
  die $class->new(%args);
}

1;
