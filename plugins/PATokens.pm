# PATokens.pm -- sauron CGI interface plugin to manage Personal Access Tokens
#
# $Id:$
#

package Sauron::Plugins::PATokens;

require Exporter;
use CGI qw/:standard *table -utf8/;
use Sauron::DB;
use Sauron::CGIutil;
use Sauron::BackEnd;
use Sauron::Sauron;
use Sauron::CGI::Utils;
use strict;
use warnings;
use vars qw($VERSION @ISA @EXPORT);

$VERSION = '$Id:$ ';

@ISA = qw(Exporter);
@EXPORT = qw(
	    );

my %pat_create_form = (
 data => [
  {ftype => 0, name => 'Create New Token'},
  {ftype => 1, tag => 'name', name => 'Token Name', type => 'text',
   len => 40, maxlen => 80, empty => 0,
   extrainfo => 'Give this token a descriptive name'},
 ]
);

my %pat_expiration_form = (
 data => [
  {ftype => 0, name => 'Token Expiration (optional)'},
  {ftype => 3, tag => 'expires', name => 'Expires', type => 'enum',
   enum => {0 => 'Never', 30 => '30 days', 90 => '90 days', 180 => '180 days', 365 => '1 year'}},
 ]
);

# TODO: Weird date format
sub format_epoch($) {
    my($ts) = @_;
    return 'Never' if (!$ts || $ts == 0);
    return localtime($ts);
}

sub menu_handler {
    my($state, $perms) = @_;

    my $selfurl = $state->{selfurl};
    my $sub = param('sub') || 'Pl_PATokens_Manage';
    my $uid = $state->{uid};

    if ($sub eq 'Pl_PATokens_Manage') {
        print h3("Personal Access Tokens");

        my @tokens;
        get_pats($uid, \@tokens);

        if (@tokens > 0) {
            print "<TABLE bgcolor=\"#ccccff\" cellspacing=1 cellpadding=1 border=0>",
                  "<TR bgcolor=\"#aaaaff\">",
                  th("Name"), th("Created"), th("Expires"), th("Last Used"), th("Last IP"), th("Actions"),
                  "</TR>\n";
            for my $t (@tokens) {
                my $trcolor = ($tokens[0][0] % 2 == 0) ? '#eeeeee' : '#ffffcc';
                my $old_sub = param('sub');
                param('sub', 'Pl_PATokens_Revoke');
                my $revoke_form = start_form(-method => 'GET', -action => $selfurl) .
                                  hidden('menu', 'login') .
                                  hidden('sub', 'Pl_PATokens_Revoke') .
                                  hidden('token_id', $t->[0]) .
                                  submit(-name => 'do_revoke', -value => 'Revoke') .
                                  end_form();
                param('sub', $old_sub);
                print "<TR bgcolor='$trcolor'>",
                      td($t->[1]),
                      td(format_epoch($t->[2])),
                      td(format_epoch($t->[3])),
                      td(format_epoch($t->[4])),
                      td($t->[5] || '-'),
                      td($revoke_form),
                      "</TR>\n";
            }
            print "</TABLE>\n";
        } else {
            print p("You have no personal access tokens.");
        }

        print hr();
        print start_form(-method => 'GET', -action => $selfurl);
        param('menu', 'login'); print hidden('menu', 'login');
        param('sub', 'Pl_PATokens_Create'); print hidden('sub', 'Pl_PATokens_Create');
        print submit(-name => 'foobar', -value => 'Create New Token');
        print end_form();

    } elsif ($sub eq 'Pl_PATokens_Create') {
        my %data;
        my $res = display_dialog("Create Personal Access Token", \%data, \%pat_create_form,
                                 'menu,sub', $selfurl);
        if ($res == 1) {
            my %result;
            my $err = create_pat($uid, $data{name}, \%result);
            if ($err < 0) {
                print h3("Error creating token (code: $err)");
            } else {
                print h3("Token Created Successfully");
                print p({-style => 'color: #cc0000; font-weight: bold;'},
                        "Copy this token now. It will not be shown again.");
                print p(input({-type => 'text', -value => $result{plain_token},
                               -size => 70, -readonly => 'readonly',
                               -style => 'font-family: monospace; font-size: 14px;'}));
                print p("Use this token in the Authorization header:");
                print pre("Authorization: $result{plain_token}");
                print start_form(-method => 'GET', -action => $selfurl);
                param('menu', 'login'); print hidden('menu', 'login');
                param('sub', 'Pl_PATokens_Manage'); print hidden('sub', 'Pl_PATokens_Manage');
                print submit(-name => 'foobar', -value => 'Back to Tokens');
                print end_form();
                return;
            }
        } elsif ($res == -1) {
            print h3("Token creation cancelled.");
        }

    } elsif ($sub eq 'Pl_PATokens_Revoke') {
        my $token_id = param('token_id');
        if (param('do_revoke')) {
            my $err = revoke_pat($token_id, $uid);
            if ($err < 0) {
                print h3("Error revoking token (code: $err)");
            } else {
                print h3("Token revoked successfully.");
            }
        } else {
            print h3("Revoke Token");
            print p("Are you sure you want to revoke this token? This action cannot be undone.");
            print start_form(-method => 'GET', -action => $selfurl);
            param('menu', 'login'); print hidden('menu', 'login');
            param('sub', 'Pl_PATokens_Revoke'); print hidden('sub', 'Pl_PATokens_Revoke');
            print hidden('token_id', $token_id);
            print hidden('do_revoke', '1');
            print submit(-name => 'foobar', -value => 'Yes, Revoke');
            print " ";
            print submit(-name => 'cancel', -value => 'Cancel');
            print end_form();
            return;
        }
    }
}

1;
# eof :-)
