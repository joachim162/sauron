package SauronAPI::Base;
use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
  strip_marker_format mark_existing_for_deletion
  build_aml_record build_mx_record
  build_value_record build_forwarder_record
);

sub strip_marker_format {
  my ($data, $api_header) = @_;
  return [] unless ref $data eq 'ARRAY' && @$data > 1;

  my $ncols = @$api_header;
  my @result;

  for my $i (1 .. $#$data) {
    my @row = @{$data->[$i]};
    shift @row;
    $#row = $ncols - 1;

    my %obj;
    for my $j (0 .. $ncols - 1) {
      $obj{$api_header->[$j]} = $row[$j] if $j < @row;
    }
    push @result, \%obj;
  }

  return \@result;
}

sub mark_existing_for_deletion {
  my ($rows, $existing_data, $count) = @_;
  return unless ref $existing_data eq 'ARRAY';

  for my $i (1 .. $#{$existing_data}) {
    my $id = $existing_data->[$i][0];
    next unless $id && $id > 0;
    my @del = ($id, ('') x ($count - 1), -1);
    push @$rows, \@del;
  }
}

sub build_aml_record {
  my ($obj) = @_;
  return [0, $obj->{mode} // 0, $obj->{ip} // '', $obj->{acl} // 0,
            $obj->{tkey} // 0, $obj->{op} // 0, $obj->{comment} // '', 2];
}

sub build_mx_record {
  my ($obj) = @_;
  return [0, $obj->{pri} // 0, $obj->{mx} // '', $obj->{comment} // '', 2];
}

sub build_value_record {
  my ($obj, $key) = @_;
  return [0, $obj->{$key} // '', $obj->{comment} // '', 2];
}

sub build_forwarder_record {
  my ($obj, $with_port) = @_;
  return $with_port
    ? [0, $obj->{ip}, $obj->{port} // '', $obj->{comment} // '', 2]
    : [0, $obj->{ip}, $obj->{comment} // '', 2];
}

1;
