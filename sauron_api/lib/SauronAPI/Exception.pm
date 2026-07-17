package SauronAPI::Exception;
use strict;
use warnings;

use Mojo::Base -base;
use overload '""' => sub { shift->stringify }, fallback => 1;

has 'message' => '';
has 'status'  => 500;
has 'kind'    => 'Internal Server Error';

sub new {
  my ($class, %args) = @_;
  return $class->SUPER::new(
    message => $args{message} // '',
    status  => $args{status}  // 500,
    kind    => $args{kind}    // 'Internal Server Error',
  );
}

sub stringify { shift->message }

sub throw {
  my ($class, %args) = @_;
  die $class->new(%args);
}

sub not_found   { shift->throw(status => 404, kind => 'Not Found',             message => shift) }
sub validation  { shift->throw(status => 400, kind => 'Bad Request',           message => shift) }
sub forbidden   { shift->throw(status => 403, kind => 'Forbidden',             message => shift) }
sub conflict    { shift->throw(status => 409, kind => 'Conflict',              message => shift) }
sub persistence { shift->throw(status => 500, kind => 'Internal Server Error', message => shift) }

1;
