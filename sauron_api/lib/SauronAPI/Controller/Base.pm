package SauronAPI::Controller::Base;
use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
  strip_marker_format mark_existing_for_deletion build_array_field
  backend_array_to_api api_array_to_backend_create api_array_to_backend_update
  build_aml_record build_mx_record build_value_record build_forwarder_record
);

# Strip BackEnd marker format from array fields to clean API objects.
# $api_header: clean column names (not the BackEnd header row).
# Data rows: [id, col1, col2, ..., marker] -- id at [0], marker at end.
# AML rows also have extra join columns after the marker (ignored).
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

# Mark existing array field rows for deletion.
# update_array_field only reads [0] (record id) and [$count] (marker=-1),
# so padding between them can be empty strings.
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

# Convert an API array field into BackEnd marker-row format.
sub build_array_field {
  my ($api_data, $field_name, $backend_headers, $builders) = @_;

  return undef unless defined $api_data && ref $api_data eq 'ARRAY';
  return undef unless exists $backend_headers->{$field_name};

  my @rows;
  push @rows, $backend_headers->{$field_name};

  my $builder = $builders->{$field_name};
  for my $item (@$api_data) {
    push @rows, $builder->($item);
  }

  return \@rows;
}

# High-level helpers that hide the marker-row wire format from controllers.

# Convert BackEnd marker rows to an API array of objects.
sub backend_array_to_api {
  my ($backend_data, $field_name, $headers) = @_;
  return strip_marker_format($backend_data, $headers->{$field_name});
}

# Convert an API array to BackEnd rows for create operations.
# $keep_header should be true for AML fields (passed to update_array_field in
# the create path) and false for fields passed to add_array_field.
sub api_array_to_backend_create {
  my ($json_data, $field_name, $backend_headers, $builders, $keep_header) = @_;
  my $data = build_array_field($json_data, $field_name, $backend_headers, $builders);
  return undef unless ref $data eq 'ARRAY';
  return $keep_header ? $data : [@{$data}[1 .. $#{$data}]];
}

# Convert an API array to BackEnd rows for update operations.
# Produces replace-all semantics: existing rows are marked for deletion, then
# new rows are appended.
sub api_array_to_backend_update {
  my ($json_data, $existing_data, $field_name, $backend_headers, $builders, $update_count) = @_;
  my $data = build_array_field($json_data, $field_name, $backend_headers, $builders);
  return undef unless ref $data eq 'ARRAY';

  my @rows = ($data->[0]);
  mark_existing_for_deletion(\@rows, $existing_data, $update_count->{$field_name});
  push @rows, @{$data}[1 .. $#{$data}];
  return \@rows;
}

# Builders for common record shapes.

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
