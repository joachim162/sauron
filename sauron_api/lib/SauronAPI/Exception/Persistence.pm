package SauronAPI::Exception::Persistence;
use Mojo::Base 'SauronAPI::Exception';

sub http_status { 500 }
sub kind        { 'Internal Server Error' }

1;
