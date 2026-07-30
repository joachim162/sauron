use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new('SauronAPI');
$t->get_ok('/')->status_is(302)->header_is(Location => '/app/');

done_testing();
