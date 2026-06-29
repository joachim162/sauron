package SauronAPI::FieldCodec;
use strict;
use warnings;

use SauronAPI::Base qw(
  strip_marker_format mark_existing_for_deletion
);

sub new {
  my ($class, %args) = @_;
  bless {
    backend_header      => $args{backend_header},
    api_columns         => $args{api_columns},
    build_row           => $args{build_row},
    marker_count        => $args{marker_count},
    create_keeps_header => $args{create_keeps_header} // 0,
  }, $class;
}

sub decode {
  my ($self, $backend_data) = @_;
  return [] unless ref $backend_data eq 'ARRAY' && @$backend_data > 1;
  return strip_marker_format($backend_data, $self->{api_columns});
}

sub encode_create {
  my ($self, $api_data) = @_;
  my $rows = $self->_build($api_data);
  return undef unless $rows;
  return $self->{create_keeps_header} ? $rows : [@{$rows}[1 .. $#{$rows}]];
}

sub encode_update {
  my ($self, $api_data, $existing) = @_;
  my $new = $self->_build($api_data);
  return undef unless $new;

  my @rows = ($new->[0]);
  mark_existing_for_deletion(\@rows, $existing, $self->{marker_count});
  push @rows, @{$new}[1 .. $#{$new}];
  return \@rows;
}

sub _build {
  my ($self, $api_data) = @_;
  return undef unless defined $api_data && ref $api_data eq 'ARRAY';

  my @rows;
  push @rows, $self->{backend_header};

  my $builder = $self->{build_row};
  for my $item (@$api_data) {
    push @rows, $builder->($item);
  }

  return \@rows;
}

1;
