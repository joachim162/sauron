package SauronAPI::Exception::Permission;
use Mojo::Base 'SauronAPI::Exception';

sub http_status { 403 }
sub kind        { 'Forbidden' }

1;
