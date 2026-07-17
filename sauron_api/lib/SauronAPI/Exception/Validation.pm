package SauronAPI::Exception::Validation;
use Mojo::Base 'SauronAPI::Exception';

sub http_status { 400 }
sub kind        { 'Bad Request' }

1;
