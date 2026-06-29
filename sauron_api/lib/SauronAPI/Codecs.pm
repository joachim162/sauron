package SauronAPI::Codecs;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(aml mx value forwarder);

use SauronAPI::Base qw(
  build_aml_record build_mx_record build_value_record build_forwarder_record
);
use SauronAPI::FieldCodec;

sub aml {
  SauronAPI::FieldCodec->new(
    backend_header      => ['aml', 0],
    api_columns         => [qw(mode ip acl tkey op comment)],
    build_row           => \&build_aml_record,
    marker_count        => 7,
    create_keeps_header => 1,
  );
}

sub mx {
  SauronAPI::FieldCodec->new(
    backend_header      => ['Priority', 'MX', 'Comments'],
    api_columns         => [qw(pri mx comment)],
    build_row           => \&build_mx_record,
    marker_count        => 4,
  );
}

sub value {
  my %args = @_;
  my $key          = $args{key}          or die "value: 'key' is required";
  my $label        = $args{label}        // ucfirst($key);
  my $has_comment  = $args{comment} // 1;
  my @bh           = $has_comment ? ($label, 'Comments') : ($label);
  my @ac           = $has_comment ? ($key, 'comment') : ($key);

  SauronAPI::FieldCodec->new(
    backend_header => \@bh,
    api_columns    => \@ac,
    build_row      => sub { build_value_record($_[0], $key) },
    marker_count   => $has_comment ? 3 : 2,
  );
}

sub forwarder {
  my %args = @_;
  my $with_port = $args{with_port} // 0;
  my @bh = $with_port ? ('IP', 'Port', 'Comments') : ('IP', 'Comments');
  my @ac = $with_port ? (qw(ip port comment)) : (qw(ip comment));

  SauronAPI::FieldCodec->new(
    backend_header => \@bh,
    api_columns    => \@ac,
    build_row      => sub { build_forwarder_record($_[0], $with_port) },
    marker_count   => $with_port ? 4 : 3,
  );
}

1;
