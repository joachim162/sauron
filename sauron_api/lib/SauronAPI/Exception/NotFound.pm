package SauronAPI::Exception::NotFound;
use Mojo::Base 'SauronAPI::Exception';

sub http_status { 404 }
sub kind        { 'Not Found' }

1;
