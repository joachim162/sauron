package SauronAPI::Exception::Conflict;
use Mojo::Base 'SauronAPI::Exception';

sub http_status { 409 }
sub kind        { 'Conflict' }

1;
