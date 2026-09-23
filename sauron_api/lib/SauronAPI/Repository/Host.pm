package SauronAPI::Repository::Host;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
  host_list host_list_server host_find host_create host_update host_delete
  host_copy host_move host_type_code host_type_slug
);

use Sauron::BackEnd ();
use Sauron::Util   qw(is_cidr is_ip);
use SauronAPI::Codecs       qw(mx value);
use SauronAPI::Exception    ();
use SauronAPI::FieldCodec;
use SauronAPI::ListQuery    qw(compile_filters parse_sort sort_sql sort_echo list_metadata set_total);
use SauronAPI::Repository   qw(dbq check_rc validate_regex with_statement_timeout LIST_STATEMENT_TIMEOUT_MS);
use JSON::PP ();

# ---------------------------------------------------------------------------
# Array fields handled by FieldCodec. Controllers MUST NOT touch these.
# ---------------------------------------------------------------------------

my @ARRAY_FIELDS = qw(
  ip ns_l ds_l wks_l mx_l dhcp_l dhcp_l6 printer_l srv_l sshfp_l tlsa_l txt_l
  alias_a subgroups
);

my %FIELDS = (
  ip        => SauronAPI::FieldCodec->new(
    backend_header => ['IP', 'reverse', 'forward'],
    api_columns    => [qw(ip reverse forward)],
    build_row      => \&_build_ip_record,
    marker_count   => 4,
  ),
  ns_l      => SauronAPI::FieldCodec->new(
    backend_header => ['NS', 'Comments'],
    api_columns    => [qw(ns comment)],
    build_row      => \&_build_ns_record,
    marker_count   => 3,
  ),
  ds_l      => SauronAPI::FieldCodec->new(
    backend_header => ['Key tag', 'Algorithm', 'Digest type', 'Digest', 'Comments'],
    api_columns    => [qw(key_tag algorithm digest_type digest comment)],
    build_row      => \&_build_ds_record,
    marker_count   => 6,
  ),
  wks_l     => SauronAPI::FieldCodec->new(
    backend_header => ['Proto', 'Services', 'Comments'],
    api_columns    => [qw(proto services comment)],
    build_row      => \&_build_wks_record,
    marker_count   => 4,
  ),
  mx_l      => mx(),
  dhcp_l    => value(key => 'dhcp', label => 'DHCP'),
  dhcp_l6   => value(key => 'dhcp', label => 'DHCP'),
  printer_l => SauronAPI::FieldCodec->new(
    backend_header => ['PRINTER', 'Comments'],
    api_columns    => [qw(printer comment)],
    build_row      => \&_build_printer_record,
    marker_count   => 3,
  ),
  srv_l     => SauronAPI::FieldCodec->new(
    backend_header => ['Priority', 'Weight', 'Port', 'Target', 'Comments'],
    api_columns    => [qw(pri weight port target comment)],
    build_row      => \&_build_srv_record,
    marker_count   => 6,
  ),
  sshfp_l   => SauronAPI::FieldCodec->new(
    backend_header => ['Algorithm', 'Type', 'Fingerprint', 'Comments'],
    api_columns    => [qw(algorithm hashtype fingerprint comment)],
    build_row      => \&_build_sshfp_record,
    marker_count   => 5,
  ),
  tlsa_l    => SauronAPI::FieldCodec->new(
    backend_header => ['Usage', 'Selector', 'Matching Type', 'Asociation Data', 'Comments'],
    api_columns    => [qw(usage selector matching_type association_data comment)],
    build_row      => \&_build_tlsa_record,
    marker_count   => 6,
  ),
  txt_l     => value(key => 'txt', label => 'Text'),
  alias_a   => SauronAPI::FieldCodec->new(
    backend_header => ['Domain'],
    api_columns    => [qw(arec)],
    build_row      => \&_build_alias_a_record,
    marker_count   => 2,
  ),
  subgroups => SauronAPI::FieldCodec->new(
    backend_header => ['SubGroup'],
    api_columns    => [qw(grp)],
    build_row      => \&_build_subgroup_record,
    marker_count   => 2,
  ),
);

# ---------------------------------------------------------------------------
# Type-specific field validation (was _validate_type_fields in controller)
# ---------------------------------------------------------------------------

my %TYPE_FIELDS = (
  1   => [qw(ips ether hinfo_hw hinfo_sw mx_l wks_l sshfp_l srv_l txt_l
             dhcp_l dhcp_l6 printer_l ns_l ds_l tlsa_l subgroups)],
  2   => [qw(ns_l ds_l)],
  3   => [qw(mx_l txt_l)],
  4   => [qw(alias cname_txt)],
  5   => [qw(printer_l dhcp_l dhcp_l6 subgroups)],
  6   => [qw(ips)],
  7   => [qw(ips mx_l txt_l alias_a)],
  8   => [qw(srv_l)],
  9   => [qw(ips ether duid iaid)],
  11  => [qw(sshfp_l)],
  12  => [qw(tlsa_l)],
  13  => [qw(txt_l)],
  101 => [qw(ips ether duid iaid)],
);

my %UNIVERSAL_FIELDS = map { $_ => 1 } qw(
  hostname type comment ttl class grp expiration
  alias cname_txt hinfo_hw hinfo_sw router ether ether_alias
  info location dept huser email model serial misc asset_id duid
  iaid flags prn wks mx rp_mbox rp_txt domain net loc
);

sub _validate_type_fields {
  my ($json, $type) = @_;

  my %valid = map { $_ => 1 } @{$TYPE_FIELDS{$type} // []};
  for my $field (keys %$json) {
    next if $UNIVERSAL_FIELDS{$field};
    return "Field '$field' is not valid for host type '" . host_type_slug($type) . "'"
      unless $valid{$field};
  }
  return undef;
}

# ---------------------------------------------------------------------------
# Host type slugs (ADR 0006). Wire representation is the slug; the database
# and BackEnd keep integer codes. This module owns the translation.
# ---------------------------------------------------------------------------

my %TYPE_CODE = (
  misc        => 0,
  host        => 1,
  delegation  => 2,
  mx          => 3,
  alias       => 4,
  printer     => 5,
  glue        => 6,
  alias_arec  => 7,
  srv         => 8,
  dhcp_only   => 9,
  zone        => 10,
  sshfp       => 11,
  tlsa        => 12,
  txt         => 13,
  naptr       => 14,
  caa         => 15,
  reservation => 101,
);
my %TYPE_SLUG = reverse %TYPE_CODE;

sub host_type_code {
  my ($slug) = @_;
  SauronAPI::Exception->validation(
    "Invalid host type '" . (defined $slug ? $slug : 'undef') . "'"
  ) unless defined $slug && exists $TYPE_CODE{$slug};
  return $TYPE_CODE{$slug};
}

sub host_type_slug {
  my ($code) = @_;
  return $TYPE_SLUG{$code} // $code;
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

my @LIST_COLUMNS = qw(
  id domain type ttl class grp alias cname_txt hinfo_hw hinfo_sw
  router ether info location dept huser email model serial misc
  asset_id comment duid iaid cdate cuser mdate muser
);

# ---------------------------------------------------------------------------
# List filters and sorting (ADR 0007)
# ---------------------------------------------------------------------------

my %SORT_COLUMN = (
  domain     => 'h.domain',
  ip         => '(SELECT MIN(ae.ip) FROM a_entries ae WHERE ae.host = h.id)',
  type       => 'h.type',
  ether      => 'h.ether',
  cdate      => 'h.cdate',
  mdate      => 'h.mdate',
  dhcp_date  => 'h.dhcp_date',
  expiration => 'h.expiration',
);

my @TXT_CAPABLE_CODES = (1, 3, 4, 7); # host, mx, alias, alias_arec

sub _fqdn_expr {
  my ($opts) = @_;
  if ($opts->{match_fqdn}) {
    return q{(CASE WHEN h.domain='@' THEN z.name ELSE h.domain || '.' || z.name END)}, [];
  }
  return undef unless defined $opts->{zone_name};
  return q{(CASE WHEN h.domain='@' THEN ? ELSE h.domain || '.' || ? END)},
    [($opts->{zone_name}) x 2];
}

# ether/duid patterns are stored in canonical hex form.
sub _hex_transform {
  my ($p) = @_;
  $p = uc $p;
  $p =~ s/[^0-9A-F]//g;
  return $p;
}

# Filter spec for ListQuery (ADR 0007). Declarative entries cover the plain
# column regexes, hinfo, and the date ranges; the custom entries own the
# host-specific semantics. The spec is built per call: context (FQDN
# expression, caller-derived group ceiling, whether txt/type were supplied)
# is captured into an explicit hash that the named _filter_* functions
# receive — never caller identity.

my %SIMPLE_REGEX_FILTERS = (map { $_ => { kind => 'regex', col => "h.$_" } }
  qw(info huser location dept model serial misc asset_id));

my %DATE_RANGE_FILTERS = (map { $_ => { kind => 'date_range', col => "h.$_" } }
  qw(dhcp_date dhcp_last cdate mdate expiration));

# q includes the hostname (label and FQDN) as well as the legacy <ANY>
# metadata fields, so finding a host by name works through the free
# search (ADR 0007 divergence).
sub _filter_q {
  my ($v, $ctx) = @_;
  my $p = validate_regex('q', $v);
  my @clauses = ('h.domain ~* ?');
  my @bind = ($p);
  if ($ctx->{fqdn}) {
    push @clauses, "$ctx->{fqdn} ~* ?";
    push @bind, @{$ctx->{fqdn_binds}}, $p;
  }
  push @clauses, map { "h.$_ ~* ?" }
    qw(location huser dept info serial model misc asset_id hinfo_hw hinfo_sw);
  push @bind, ($p) x 10;
  return { clauses => [ '(' . join(' OR ', @clauses) . ')' ], bind => \@bind };
}

# Leading *. is a literal wildcard record label, not a regex quantifier.
sub _filter_domain {
  my ($v, $ctx) = @_;
  (my $p = $v) =~ s/^\*\./\\\*\\\./;
  $p = validate_regex('domain', $p);
  return { clauses => [ $ctx->{match_fqdn}
    ? q{(h.domain ~* ? OR (CASE WHEN h.domain='@' THEN z.name ELSE h.domain || '.' || z.name END) ~* ?)}
    : 'h.domain ~* ?'
  ], bind => $ctx->{match_fqdn} ? [$p, $p] : [$p] };
}

sub _filter_txt {
  my ($v, $ctx) = @_;
  my $p = validate_regex('txt', $v);
  my @clauses =
    ('EXISTS (SELECT 1 FROM txt_entries te WHERE te.type=2 AND te.ref=h.id AND te.txt ~* ?)');
  # legacy parity
  push @clauses, 'h.type IN (1,3,4,7)' unless $ctx->{type_supplied};
  return { clauses => \@clauses, bind => [$p] };
}

sub _filter_type {
  my ($v, $ctx) = @_;
  my $code = host_type_code($v);
  # txt + a TXT-incapable type is a provably empty combination
  # (ADR 0007): short-circuit instead of silently ignoring a filter.
  return { clauses => [], bind => [], empty => 1 }
    if $ctx->{txt_supplied} && !grep { $_ == $code } @TXT_CAPABLE_CODES;
  return { clauses => ['(h.type=1 OR h.type=101)'] } # host includes reservation
    if $code == 1;
  return { clauses => ['h.type=?'], bind => [$code] };
}

sub _filter_ip {
  my ($v) = @_;
  my $op;
  if ($v =~ m{/}) {
    SauronAPI::Exception->validation("Invalid CIDR '$v' for 'ip'") unless is_cidr($v);
    $op = '<<=';
  } else {
    SauronAPI::Exception->validation("Invalid IP address '$v' for 'ip'") unless is_ip($v);
    $op = '=';
  }
  return { clauses =>
    ["EXISTS (SELECT 1 FROM a_entries ae WHERE ae.host=h.id AND ae.ip $op ?)"],
    bind => [$v] };
}

# Group picker parity (ADR 0007): a group above the caller's derived
# ceiling behaves as unknown.
sub _filter_group {
  my ($v, $ctx) = @_;
  my $rows = dbq("SELECT id, alevel FROM groups WHERE server=? AND name=?",
    $ctx->{server_id}, $v);
  if (!@$rows || (defined $ctx->{ceiling} && ($rows->[0][1] // 0) > $ctx->{ceiling})) {
    SauronAPI::Exception->validation("Unknown group '$v'");
  }
  my $gid = $rows->[0][0];
  return {
    clauses => ['(h.grp=? OR EXISTS (SELECT 1 FROM group_entries ge WHERE ge.host=h.id AND ge.grp=?))'],
    bind    => [$gid, $gid],
  };
}

sub _filter_iaid {
  my ($v) = @_;
  my $p = uc $v;
  $p =~ s/[^0-9A-F]//g;
  $p = hex($p) if $p ne '' && $p !~ /^\d+$/;
  SauronAPI::Exception->validation("Invalid IAID '$v'")
    unless defined $p && $p =~ /^\d+$/ && $p > 0 && $p < 2**32;
  return { clauses => ['h.iaid = ?'], bind => [$p] };
}

sub _filter_mx {
  my ($v) = @_;
  my $p = validate_regex('mx', $v);
  return {
    clauses => ['EXISTS (SELECT 1 FROM mx_templates m WHERE m.id=h.mx AND m.zone=h.zone AND m.name ~* ?)'],
    bind    => [$p],
  };
}

sub _filter_spec {
  my ($server_id, $f, $opts) = @_;

  my ($fqdn, $fqdn_binds) = _fqdn_expr($opts);
  my $ctx = {
    server_id     => $server_id,
    fqdn          => $fqdn,
    fqdn_binds    => $fqdn_binds,
    match_fqdn    => $opts->{match_fqdn},
    ceiling       => $opts->{max_group_alevel},
    txt_supplied  => defined $f->{txt} && length $f->{txt},
    type_supplied => defined $f->{type} && length $f->{type},
  };

  return {
    %SIMPLE_REGEX_FILTERS,
    ether => { kind => 'regex', col => 'h.ether', transform => \&_hex_transform },
    duid  => { kind => 'regex', col => 'h.duid',  transform => \&_hex_transform },
    hinfo => { kind => 'regex_any', cols => ['h.hinfo_hw', 'h.hinfo_sw'] },
    %DATE_RANGE_FILTERS,
    q      => { kind => 'custom', code => sub { _filter_q($_[0], $ctx) } },
    domain => { kind => 'custom', code => sub { _filter_domain($_[0], $ctx) } },
    txt    => { kind => 'custom', code => sub { _filter_txt($_[0], $ctx) } },
    type   => { kind => 'custom', code => sub { _filter_type($_[0], $ctx) } },
    ip     => { kind => 'custom', code => sub { _filter_ip($_[0]) } },
    group  => { kind => 'custom', code => sub { _filter_group($_[0], $ctx) } },
    iaid   => { kind => 'custom', code => sub { _filter_iaid($_[0]) } },
    mx     => { kind => 'custom', code => sub { _filter_mx($_[0]) } },
  };
}

# Group names for list/detail enrichment. Ungated (legacy parity): the CGI
# host view prints the current group's name regardless of its alevel
# (grp_rec); alevel gating applies to group selection and the group
# filter, not to display.
sub _group_names {
  my ($grps) = @_;
  my %names;
  my %seen;
  my @ids = grep { defined $_ && $_ > 0 && !$seen{$_}++ } @$grps;
  return %names unless @ids;
  my $placeholders = join ',', ('?') x @ids;
  my $rows = dbq("SELECT id, name FROM groups WHERE id IN ($placeholders)", @ids);
  $names{$_->[0]} = $_->[1] for @$rows;
  return %names;
}

# Shared preparation for both host list scopes (ADR 0007): page/per-page,
# sort, filter compilation and the metadata envelope. The scope-specific
# part is exactly $opts{spec_opts}: zone-scoped domain matching is
# label-only (zone_name), server-scoped matching includes the FQDN
# (match_fqdn, divergence 11 in docs/host-filtering-architecture-review.md).
sub _prepare_host_list {
  my ($server_id, %opts) = @_;
  my $page    = $opts{page}     // 1;
  my $per_page = $opts{per_page} // 50;
  my $params  = $opts{params} // {};
  my $sort    = parse_sort($opts{sort}, \%SORT_COLUMN, default => 'domain', tiebreak => 'h.id');
  my $spec_opts = { max_group_alevel => $opts{max_group_alevel}, %{$opts{spec_opts} // {}} };
  my $filters = compile_filters($params, _filter_spec($server_id, $params, $spec_opts));
  my $meta    = list_metadata($page, $per_page, sort_echo($sort), $filters->{echo});
  return ($meta, $sort, $filters, $page, $per_page);
}

# Shared execution for both host list scopes: an impossible filter
# combination short-circuits to an empty page, and the row and count
# queries always share the caller-built predicate (they are derived from
# the same compiled $filters) and run under the defensive statement timeout.
sub _run_host_list {
  my (%args) = @_;
  return ([], $args{meta}) if $args{filters}{empty};
  my ($rows, $total_rows);
  with_statement_timeout(LIST_STATEMENT_TIMEOUT_MS, sub {
    $rows       = dbq($args{row_sql},   @{$args{row_bind}});
    $total_rows = dbq($args{count_sql}, @{$args{count_bind}});
  });
  set_total($args{meta}, $total_rows->[0][0] // 0);
  return ($rows, $args{meta});
}

sub host_list {
  my ($server_id, $zone_id, %opts) = @_;

  my $zone_row  = dbq("SELECT name FROM zones WHERE id=?", $zone_id);
  my $zone_name = @$zone_row ? $zone_row->[0][0] : undef;

  my ($meta, $sort, $filters, $page, $per_page) =
    _prepare_host_list($server_id, %opts, spec_opts => { zone_name => $zone_name });
  my $offset = ($page - 1) * $per_page;

  my @bind  = ($zone_id);
  my $where_sql = ' WHERE h.zone=?';
  if ($filters->{where}) {
    $where_sql .= " AND $filters->{where}";
    push @bind, @{$filters->{bind}};
  }

  my ($rows) = _run_host_list(
    meta       => $meta,
    filters    => $filters,
    row_sql    => "SELECT " . join(',', map { "h.$_" } @LIST_COLUMNS) . " FROM hosts h$where_sql " .
                  sort_sql($sort) . " LIMIT ? OFFSET ?",
    row_bind   => [@bind, $per_page, $offset],
    count_sql  => "SELECT COUNT(*) FROM hosts h$where_sql",
    count_bind => \@bind,
  );

  my %host_ips  = _batch_host_ips($rows);
  my %grp_names = _group_names([map $_->[5], @$rows]);

  my @data;
  for my $row (@$rows) {
    push @data, _build_host_list_item($server_id, $zone_id, $zone_name, $row, $host_ips{$row->[0]}, \%grp_names);
  }

  return (\@data, $meta);
}

# Server-scoped cross-zone host collection (ADR 0005). $ids is the
# visible-zone allowlist: undef = unfiltered, [] = short-circuit empty.
sub host_list_server {
  my ($server_id, %opts) = @_;

  my ($meta, $sort, $filters, $page, $per_page) =
    _prepare_host_list($server_id, %opts, spec_opts => { match_fqdn => 1 });
  my $offset = ($page - 1) * $per_page;

  my @bind  = ($server_id);
  my $where = " WHERE z.server=?";
  my $ids   = $opts{ids};
  if ($ids) {
    return ([], $meta) unless @$ids;
    $where .= " AND h.zone IN (" . join(',', ('?') x @$ids) . ")";
    push @bind, @$ids;
  }
  if ($filters->{where}) {
    $where .= " AND $filters->{where}";
    push @bind, @{$filters->{bind}};
  }

  my @cols = map { "h.$_" } @LIST_COLUMNS;
  my ($rows) = _run_host_list(
    meta       => $meta,
    filters    => $filters,
    row_sql    => "SELECT h.zone," . join(',', @cols) . ",z.name " .
                  "FROM hosts h JOIN zones z ON z.id=h.zone$where " . sort_sql($sort) . " LIMIT ? OFFSET ?",
    row_bind   => [@bind, $per_page, $offset],
    count_sql  => "SELECT COUNT(*) FROM hosts h JOIN zones z ON z.id=h.zone$where",
    count_bind => \@bind,
  );

  # Row layout: h.zone, LIST_COLUMNS..., z.name. Shift/pop off the extras
  # so %host_ips keys on the id column before item building.
  my %host_ips;
  {
    my @host_ids = map $_->[1], @$rows;
    %host_ips = _batch_host_ips_ids(@host_ids);
  }
  my %grp_names = _group_names([map $_->[6], @$rows]);

  my @data;
  for my $row (@$rows) {
    my @values = @$row;
    my $zone_id   = shift @values;
    my $zone_name = pop @values;
    push @data, _build_host_list_item($server_id, $zone_id, $zone_name, \@values, $host_ips{$row->[1]}, \%grp_names);
  }

  return (\@data, $meta);
}

sub _batch_host_ips {
  my ($rows) = @_;
  return () unless @$rows;
  return _batch_host_ips_ids(map $_->[0], @$rows);
}

sub _batch_host_ips_ids {
  my @host_ids = @_;
  return () unless @host_ids;
  my $placeholders = join ',', ('?') x @host_ids;
  my $ip_rows = dbq(
    "SELECT host, ip FROM a_entries WHERE host IN ($placeholders) ORDER BY host, ip",
    @host_ids
  );
  my %host_ips;
  for my $row (@$ip_rows) {
    push @{$host_ips{$row->[0]}}, $row->[1];
  }
  return %host_ips;
}

sub _build_host_list_item {
  my ($server_id, $zone_id, $zone_name, $row, $ips, $grp_names) = @_;

  my %item;
  @item{@LIST_COLUMNS} = @$row;
  $item{type} = host_type_slug($item{type});
  $item{cuser} =~ s/\s+$// if defined $item{cuser};
  $item{muser} =~ s/\s+$// if defined $item{muser};
  $item{zone_id} = $zone_id;
  $item{zone} = $zone_name;
  $item{server_id} = $server_id;
  $item{fqdn} = defined $zone_name
    ? ($item{domain} // '') eq '@' ? $zone_name : "$item{domain}.$zone_name"
    : undef;
  $item{host_group} = defined $item{grp} && $item{grp} > 0 ? $grp_names->{$item{grp}} : undef;
  $item{ips} = $ips // [];
  return \%item;
}

sub host_find {
  my ($server_id, $zone_id, $hostname, %opts) = @_;

  my $host_id = _host_id($zone_id, $hostname);
  my %host_data;
  check_rc(Sauron::BackEnd::get_host($host_id, \%host_data),
         'Failed to retrieve host data');

  return _build_host_response($host_id, \%host_data, $zone_id, $server_id, \%opts);
}

sub host_create {
  my ($server_id, $zone_id, $input, %opts) = @_;

  my $hostname = $input->{hostname}
    or SauronAPI::Exception->validation("'hostname' is required");

  my $existing_id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  if ($existing_id > 0) {
    SauronAPI::Exception->conflict(
      "Host '$hostname' already exists in this zone (id=$existing_id)"
    );
  }

  my $type = exists $input->{type} ? host_type_code($input->{type}) : 1;
  $input->{type} = $type;

  if (my $err = _validate_type_fields($input, $type)) {
    SauronAPI::Exception->validation($err);
  }

  # BackEnd::add_host reads only the scalar 'alias' for type 7 and would
  # silently drop an alias_a array; reject it instead of losing data.
  if ($type == 7 && exists $input->{alias_a}) {
    SauronAPI::Exception->validation(
      "Field 'alias_a' cannot be used when creating a type 7 host; " .
      "set the AREC target with 'alias' (host ID). " .
      "Additional targets can be added via update."
    );
  }

  my %rec = (
    zone   => $zone_id,
    domain => $hostname,
    type   => $type,
  );
  _copy_host_fields(\%rec, $input);

  # TODO: when creating an alias (alias > 0) and ttl is not provided,
  # inherit the source host's TTL to match legacy CGI behaviour.
  # The frontend currently sends ttl explicitly; move that rule here.

  _resolve_ips_for_create(\%rec, $input, $server_id, $type, $opts{on_ip});

  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';
    next unless exists $input->{$field};
    my $data = $FIELDS{$field}->encode_create($input->{$field});
    next unless ref $data eq 'ARRAY';
    $rec{$field} = $data;
  }

  my $host_id = _add_host(\%rec);

  my %host_data;
  check_rc(Sauron::BackEnd::get_host($host_id, \%host_data),
         'Host created but failed to retrieve data');

  return _build_host_response($host_id, \%host_data, $zone_id, $server_id, \%opts);
}

sub host_update {
  my ($server_id, $zone_id, $hostname, $input, %opts) = @_;

  my $host_id = _host_id($zone_id, $hostname);

  my %host_data;
  check_rc(Sauron::BackEnd::get_host($host_id, \%host_data),
         'Failed to retrieve host data');

  if (exists $input->{type}) {
    my $to = host_type_code($input->{type});
    if ($to != $host_data{type}) {
      my $from = $host_data{type};
      unless (($from == 1 && $to == 101) || ($from == 101 && $to == 1)) {
        SauronAPI::Exception->validation("'type' is immutable after creation");
      }
    }
    $input->{type} = $to;
  }

  if (my $err = _validate_type_fields($input, $host_data{type})) {
    SauronAPI::Exception->validation($err);
  }

  my %rec = (
    id     => $host_id,
    zone   => $host_data{zone},
    type   => $host_data{type},
    domain => $host_data{domain},
  );
  _copy_host_fields(\%rec, $input);

  # Always carry existing IPs so BackEnd validation (host_required_data_error)
  # does not reject the update when ip field is absent from the request body.
  $rec{ip} = $host_data{ip};
  if (exists $input->{ips}) {
    my $data = $FIELDS{ip}->encode_update(
      _normalize_ip_entries($input->{ips}), $host_data{ip});
    $rec{ip} = $data if ref $data eq 'ARRAY';
  }

  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';
    next unless exists $input->{$field};
    my $data = $FIELDS{$field}->encode_update($input->{$field}, $host_data{$field});
    $rec{$field} = $data if ref $data eq 'ARRAY';
  }

  my $res = Sauron::BackEnd::update_host(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence(
      "Failed to update host (code: $res)"
    );
  }

  if (Sauron::BackEnd::get_host($host_id, \%host_data) != 0) {
    SauronAPI::Exception->persistence(
      'Host updated but failed to retrieve data'
    );
  }

  return _build_host_response($host_id, \%host_data, $host_data{zone}, $server_id, \%opts);
}

sub host_delete {
  my ($server_id, $zone_id, $hostname) = @_;

  my $host_id = _host_id($zone_id, $hostname);

  my $res = Sauron::BackEnd::delete_host($host_id);
  if ($res < 0) {
    SauronAPI::Exception->persistence(
      "Failed to delete host (code: $res)"
    );
  }
  return;
}

sub host_copy {
  my ($server_id, $zone_id, $source_hostname, $input, %opts) = @_;

  my $source_id = _host_id($zone_id, $source_hostname);
  my %source;
  check_rc(Sauron::BackEnd::get_host($source_id, \%source),
         'Failed to retrieve source host data');

  # Determine effective type for validation (input is a slug, stored type a code)
  my $effective_type = exists $input->{type} ? host_type_code($input->{type}) : $source{type};
  $input->{type} = $effective_type if exists $input->{type};

  # Validate array fields against the effective type (parity with host_create)
  if (my $err = _validate_type_fields($input, $effective_type)) {
    SauronAPI::Exception->validation($err);
  }

  # Build new record from source + overrides
  my %rec = (
    zone   => $zone_id,
    domain => $source{domain},
    type   => $source{type},
  );

  # Copy scalar fields from source, apply overrides
  my @scalar = qw(
    domain ttl type class grp alias cname_txt hinfo_hw hinfo_sw loc router
    info location dept huser email model misc comment
    flags expiration prn wks mx rp_mbox rp_txt
  );
  for my $f (@scalar) {
    if (exists $input->{$f}) {
      $rec{$f} = $input->{$f};
    } elsif (defined $source{$f}) {
      $rec{$f} = $source{$f};
    }
  }

  # Device-specific fields are never copied from source (matching CGI's
  # copy behaviour), but an explicit value in the request is honoured.
  for my $f (qw(ether duid iaid serial asset_id)) {
    $rec{$f} = $input->{$f}
      if defined $input->{$f} && $input->{$f} ne '';
  }

  # Hostname: auto-generate or use input
  if (my $hn = $input->{hostname}) {
    my $existing = Sauron::BackEnd::get_host_id($zone_id, $hn);
    if ($existing > 0) {
      SauronAPI::Exception->conflict(
        "Host '$hn' already exists in this zone (id=$existing)"
      );
    }
    $rec{domain} = $hn;
  } else {
    $rec{domain} = _auto_hostname($zone_id, $source{domain});
  }

  # IPs: use input, or auto-assign from source's first IP network
  if (exists $input->{ips} || exists $input->{net}) {
    _resolve_ips_for_create(\%rec, $input, $server_id, $rec{type}, $opts{on_ip});
  } elsif ($effective_type == 1 || $effective_type == 6 || $effective_type == 9 || $effective_type == 101) {
    # Auto-assign IP from source's network (CGI copy behaviour).
    my $first_ip;
    if (ref $source{ip} eq 'ARRAY' && @{$source{ip}} > 1) {
      $first_ip = $source{ip}[1][1];
    }
    unless ($first_ip) {
      SauronAPI::Exception->validation(
        "Cannot auto-assign IP: source host has no IP addresses; provide 'ips' or 'net' explicitly"
      );
    }
    my $cidr = Sauron::BackEnd::get_net_cidr_by_ip($server_id, $first_ip);
    unless ($cidr) {
      SauronAPI::Exception->validation(
        "Cannot auto-assign IP: source IP '$first_ip' is not in any known network; provide 'ips' or 'net' explicitly"
      );
    }
    my $policy = Sauron::BackEnd::get_net_ip_policy($server_id, $cidr);
    my $ip = Sauron::BackEnd::get_free_ip_by_net($server_id, $cidr, $rec{ether} // '', '', $policy);
    unless (is_cidr($ip)) {
      SauronAPI::Exception->validation(
        "Cannot auto-assign IP from network '$cidr': $ip"
      );
    }
    $opts{on_ip}->($ip) if $opts{on_ip};
    my $data = $FIELDS{ip}->encode_create([[$ip, 't', 't']]);
    $rec{ip} = $data if ref $data eq 'ARRAY';
  }

  # Array fields from source, overridden by input. Source arrays that are
  # not valid for the effective type are dropped (a type override would
  # otherwise build a hybrid record).
  my %valid_for_type = map { $_ => 1 } @{$TYPE_FIELDS{$effective_type} // []};
  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';
    if (exists $input->{$field}) {
      my $data = $FIELDS{$field}->encode_create($input->{$field});
      $rec{$field} = $data if ref $data eq 'ARRAY';
    } elsif (ref $source{$field} eq 'ARRAY' && @{$source{$field}} > 1) {
      next unless $valid_for_type{$field};
      my $decoded = $FIELDS{$field}->decode($source{$field});
      my $data = $FIELDS{$field}->encode_create($decoded);
      $rec{$field} = $data if ref $data eq 'ARRAY';
    }
  }

  # Let the controller inspect the final merged record (e.g. RHF check).
  $opts{on_merged}->(\%rec) if $opts{on_merged};

  my $host_id = _add_host(\%rec);

  my %host_data;
  check_rc(Sauron::BackEnd::get_host($host_id, \%host_data),
         'Host created but failed to retrieve data');

  return _build_host_response($host_id, \%host_data, $zone_id, $server_id, \%opts);
}

sub _auto_hostname {
  my ($zone_id, $domain) = @_;

  my ($prefix, $suffix);
  if ($domain =~ /^([^\.]+)(\..*)?$/) {
    $prefix = $1;
    $suffix = $2 // '';
  } else {
    $prefix = $domain;
    $suffix = '';
  }

  my $candidate;
  if ($prefix =~ /(\d+)$/) {
    my $num = $1;
    my $fmt = '%0' . length($num) . 'd';
    do {
      $num++;
      (my $new_prefix = $prefix) =~ s/\Q$1\E$/sprintf($fmt, $num)/e;
      $candidate = $new_prefix . $suffix;
    } while (Sauron::BackEnd::get_host_id($zone_id, $candidate) > 0);
  } else {
    my $n = 2;
    do {
      $candidate = $prefix . $n . $suffix;
      $n++;
    } while (Sauron::BackEnd::get_host_id($zone_id, $candidate) > 0);
  }

  return $candidate;
}

sub host_move {
  my ($server_id, $zone_id, $hostname, $input, %opts) = @_;

  my $host_id = _host_id($zone_id, $hostname);
  my %host;
  check_rc(Sauron::BackEnd::get_host($host_id, \%host),
         'Failed to retrieve host data');

  if ($host{type} != 1) {
    SauronAPI::Exception->validation("Move is only available for host type 'host'");
  }

  my $has_ip   = exists $input->{ip};
  my $has_net  = exists $input->{net};
  my $has_zone = exists $input->{zone};

  if ($has_zone && ($has_ip || $has_net)) {
    SauronAPI::Exception->validation("Cannot combine zone move with ip/net");
  }
  if ($has_ip && $has_net) {
    SauronAPI::Exception->validation("'ip' and 'net' are mutually exclusive");
  }
  unless ($has_ip || $has_net || $has_zone) {
    SauronAPI::Exception->validation("One of 'ip', 'net', or 'zone' is required");
  }

  if ($has_ip || $has_net) {
    return _move_ip($server_id, $zone_id, $host_id, \%host, $input, \%opts);
  } else {
    return _move_zone($server_id, $zone_id, $host_id, \%host, $input, \%opts);
  }
}

sub _move_ip {
  my ($server_id, $zone_id, $host_id, $host, $input, $opts) = @_;

  my $new_ip;
  if (exists $input->{net}) {
    my $net = $input->{net};
    my $cidr;
    my $net_id = Sauron::BackEnd::get_net_by_cidr($server_id, $net);
    if ($net_id > 0) {
      my %net_data;
      Sauron::BackEnd::get_net($net_id, \%net_data);
      $cidr = $net_data{net};
    } else {
      my $q = dbq("SELECT net FROM nets WHERE server=? AND netname=?",
                  $server_id, $net);
      $cidr = $q->[0][0] if @$q > 0;
    }
    unless ($cidr) {
      SauronAPI::Exception->validation("Network '$net' not found on this server");
    }
    my $policy = Sauron::BackEnd::get_net_ip_policy($server_id, $cidr);
    $new_ip = Sauron::BackEnd::get_free_ip_by_net(
      $server_id, $cidr, $host->{ether} // '', undef, $policy
    );
    unless (is_cidr($new_ip)) {
      SauronAPI::Exception->validation("IP assignment failed: $new_ip");
    }
  } else {
    $new_ip = $input->{ip};
    unless (is_cidr($new_ip)) {
      SauronAPI::Exception->validation("Invalid IP address '$new_ip'");
    }
  }

  $opts->{on_ip}->($new_ip) if $opts->{on_ip};

  if (Sauron::BackEnd::ip_in_use($server_id, $new_ip) > 0) {
    SauronAPI::Exception->conflict("IP '$new_ip' is already in use");
  }

  my @ips = @{$host->{ip}};
  my $from_ip = $input->{from_ip};
  my $found_idx;
  if ($from_ip) {
    for my $i (1 .. $#ips) {
      if ($ips[$i][1] eq $from_ip) { $found_idx = $i; last; }
    }
    SauronAPI::Exception->validation("IP '$from_ip' not found on this host")
      unless $found_idx;
  } else {
    if (@ips > 2) {
      SauronAPI::Exception->validation(
        "Host has multiple IPs; 'from_ip' is required to specify which to move"
      );
    }
    $found_idx = 1;
  }

  $ips[$found_idx][1] = $new_ip;
  $ips[$found_idx][4] = 1;

  my %rec = (
    id     => $host_id,
    zone   => $host->{zone},
    type   => $host->{type},
    domain => $host->{domain},
    ip     => \@ips,
  );

  my $res = Sauron::BackEnd::update_host(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence("Failed to move host (code: $res)");
  }

  my %updated;
  check_rc(Sauron::BackEnd::get_host($host_id, \%updated),
         'Host moved but failed to retrieve data');
  return _build_host_response($host_id, \%updated, $host->{zone}, $server_id, $opts);
}

sub _move_zone {
  my ($server_id, $zone_id, $host_id, $host, $input, $opts) = @_;

  my $target_zone = $input->{zone};
  my $new_zone_id = Sauron::BackEnd::get_zone_id($target_zone, $server_id);
  if ($new_zone_id <= 0) {
    SauronAPI::Exception->not_found("Zone '$target_zone' not found on this server");
  }

  if ($new_zone_id == $zone_id) {
    SauronAPI::Exception->validation("Cannot move to the same zone");
  }

  # Pre-check: hostname must not conflict in the target zone (409 per spec).
  my $existing = Sauron::BackEnd::get_host_id($new_zone_id, $host->{domain});
  if ($existing > 0 && $existing != $host_id) {
    SauronAPI::Exception->conflict(
      "Host '$host->{domain}' already exists in zone '$target_zone' (id=$existing)"
    );
  }

  my %rec = (
    id     => $host_id,
    zone   => $new_zone_id,
    type   => $host->{type},
    domain => $host->{domain},
    mx     => -1,
  );

  $rec{ip} = $host->{ip} if ref $host->{ip} eq 'ARRAY';

  my $res = Sauron::BackEnd::update_host(\%rec);
  if ($res < 0) {
    SauronAPI::Exception->persistence("Failed to move host (code: $res)");
  }

  my %updated;
  check_rc(Sauron::BackEnd::get_host($host_id, \%updated),
         'Host moved but failed to retrieve data');
  return _build_host_response($host_id, \%updated, $new_zone_id, $server_id, $opts);
}

# ---------------------------------------------------------------------------
# Internal helpers (continued)
# ---------------------------------------------------------------------------

sub _host_id {
  my ($zone_id, $hostname) = @_;
  my $id = Sauron::BackEnd::get_host_id($zone_id, $hostname);
  SauronAPI::Exception->not_found(
    "Host '$hostname' not found in zone"
  ) if $id <= 0;
  return $id;
}

# add_host returns -27 when required data for the host type is missing
# (e.g. type 1 without IPs) — a client error, so map it to 400 with the
# BackEnd's own explanation instead of a generic 500.
sub _add_host {
  my ($rec) = @_;
  my $host_id = Sauron::BackEnd::add_host($rec);
  if ($host_id == -27) {
    my $err = Sauron::BackEnd::host_required_data_error($rec);
    SauronAPI::Exception->validation(
      ($err && $err ne '') ? $err : "Missing required data for host type '" . host_type_slug($rec->{type}) . "'"
    );
  }
  if ($host_id < 0) {
    SauronAPI::Exception->persistence(
      "Failed to create host (code: $host_id)"
    );
  }
  return $host_id;
}

sub _copy_host_fields {
  my ($rec, $json) = @_;
  my @scalar_fields = qw(
    domain ttl type class grp alias cname_txt hinfo_hw hinfo_sw router ether ether_alias
    info location dept huser email model serial misc asset_id comment duid
    iaid flags expiration prn wks mx rp_mbox rp_txt loc
  );
  for my $field (@scalar_fields) {
    $rec->{$field} = $json->{$field} if exists $json->{$field};
  }
}

sub _resolve_ips_for_create {
  my ($rec, $input, $server_id, $type, $on_ip) = @_;

  my $net = $input->{net};
  my $ips = $input->{ips};

  if ($net) {
    unless ($type == 1 || $type == 101) {
      SauronAPI::Exception->validation(
      "Auto-assignment ('net') is only valid for host types 'host' and 'reservation'"
      );
    }
  }

  if ($net and defined $ips) {
    SauronAPI::Exception->validation(
      "Provide either 'net' (auto-assign) or 'ips' (manual), not both"
    );
  }

  if ($net) {
    my $cidr;
    my $net_id = Sauron::BackEnd::get_net_by_cidr($server_id, $net);
    if ($net_id > 0) {
      my %net_data;
      Sauron::BackEnd::get_net($net_id, \%net_data);
      $cidr = $net_data{net};
    } else {
      my $q = dbq("SELECT net FROM nets WHERE server=? AND netname=?",
                  $server_id, $net);
      $cidr = $q->[0][0] if @$q > 0;
    }
    unless ($cidr) {
      SauronAPI::Exception->validation(
        "Network '$net' not found on this server"
      );
    }

    my $ip_policy = Sauron::BackEnd::get_net_ip_policy($server_id, $cidr);
    my $ip = Sauron::BackEnd::get_free_ip_by_net(
      $server_id, $cidr, $rec->{ether} // '', undef, $ip_policy
    );
    unless (is_cidr($ip)) {
      SauronAPI::Exception->validation(
        "IP assignment failed: $ip"
      );
    }
    $on_ip->($ip) if $on_ip;
    my $data = $FIELDS{ip}->encode_create([[$ip, 't', 't']]);
    $rec->{ip} = $data if ref $data eq 'ARRAY';
    return;
  }

  if (defined $ips) {
    my $triples = _normalize_ip_entries($ips);
    for my $triple (@$triples) {
      my $ip = $triple->[0];
      unless (is_cidr($ip)) {
        SauronAPI::Exception->validation(
          "Invalid IP address '$ip'"
        );
      }
      if (Sauron::BackEnd::ip_in_use($server_id, $ip) > 0) {
        SauronAPI::Exception->conflict(
          "IP address '$ip' is already in use"
        );
      }
      $on_ip->($ip) if $on_ip;
    }
    my $data = $FIELDS{ip}->encode_create($triples);
    $rec->{ip} = $data if ref $data eq 'ARRAY';
  }
}

# Normalize API ips input ([{ip, reverse?, forward?}, ...]) into marker
# triples [ip, 't'/'f', 't'/'f']. Flags default to true when omitted.
sub _normalize_ip_entries {
  my ($ips) = @_;
  SauronAPI::Exception->validation("'ips' must be an array")
    unless ref $ips eq 'ARRAY';

  my @out;
  for my $entry (@$ips) {
    SauronAPI::Exception->validation(
      "Each 'ips' item must be an object with an 'ip' field"
    ) unless ref $entry eq 'HASH' && defined $entry->{ip} && length $entry->{ip};
    my $rev = exists $entry->{reverse} ? ($entry->{reverse} ? 't' : 'f') : 't';
    my $fwd = exists $entry->{forward} ? ($entry->{forward} ? 't' : 'f') : 't';
    push @out, [$entry->{ip}, $rev, $fwd];
  }
  return \@out;
}

# ---------------------------------------------------------------------------
# Response builder (was _build_host_response in controller)
# ---------------------------------------------------------------------------

sub _build_host_response {
  my ($host_id, $host_data, $zone_id, $server_id, $opts) = @_;

  my ($server_name, $zone_name);
  if ($zone_id > 0) {
    my %zone_data;
    if (Sauron::BackEnd::get_zone($zone_id, \%zone_data) == 0) {
      $zone_name = $zone_data{name};
      my $sid = $server_id || $zone_data{server};
      if ($sid > 0) {
        my %server_data;
        if (Sauron::BackEnd::get_server($sid, \%server_data) == 0) {
          $server_name = $server_data{name};
        }
      }
    }
  }

  my @ips;
  if (ref $host_data->{ip} eq 'ARRAY' && @{$host_data->{ip}} > 1) {
    for my $i (1 .. $#{$host_data->{ip}}) {
      my $r = $host_data->{ip}[$i];
      next unless defined $r->[1];
      push @ips, {
        ip      => $r->[1],
        reverse => ($r->[2] // 'f') eq 't' ? JSON::PP::true : JSON::PP::false,
        forward => ($r->[3] // 'f') eq 't' ? JSON::PP::true : JSON::PP::false,
      };
    }
  }

  my %grp_names = _group_names([$host_data->{grp}]);

  # Same fqdn construction as the list items (_build_host_list_item):
  # the bare zone name for apex records, no trailing dot. BackEnd's own
  # fqdn ('\@.zone.') would not round-trip with the list or the filters.
  my $fqdn = defined $zone_name && defined $host_data->{domain}
    ? ($host_data->{domain} // '') eq q{@} ? $zone_name : "$host_data->{domain}.$zone_name"
    : ($host_data->{fqdn} // '');

  my $response = {
    id                => $host_id,
    domain            => $host_data->{domain},
    fqdn              => $fqdn,
    zone_id           => $zone_id,
    server_id         => $server_id,
    server            => $server_name,
    type              => host_type_slug($host_data->{type}),
    ttl               => $host_data->{ttl},
    class             => $host_data->{class},
    grp               => $host_data->{grp},
    host_group        => defined $host_data->{grp} && $host_data->{grp} > 0
                         ? $grp_names{$host_data->{grp}} : undef,
    alias             => $host_data->{alias},
    cname_txt         => $host_data->{cname_txt},
    hinfo_hw          => $host_data->{hinfo_hw},
    hinfo_sw          => $host_data->{hinfo_sw},
    loc               => $host_data->{loc},
    wks               => $host_data->{wks},
    mx                => $host_data->{mx},
    rp_mbox           => $host_data->{rp_mbox},
    rp_txt            => $host_data->{rp_txt},
    router            => $host_data->{router},
    prn               => defined $host_data->{prn} ? ($host_data->{prn} eq 't' ? JSON::PP::true : JSON::PP::false) : JSON::PP::false,
    ips               => \@ips,
    ether             => $host_data->{ether},
    ether_alias       => $host_data->{ether_alias},
    ether_alias_info  => $host_data->{ether_alias_info},
    info              => $host_data->{info},
    location          => $host_data->{location},
    dept              => $host_data->{dept},
    huser             => $host_data->{huser},
    email             => $host_data->{email},
    model             => $host_data->{model},
    serial            => $host_data->{serial},
    misc              => $host_data->{misc},
    asset_id          => $host_data->{asset_id},
    dhcp_date         => $host_data->{dhcp_date},
    dhcp_date_str     => $host_data->{dhcp_date_str},
    dhcp_info         => $host_data->{dhcp_info},
    comment           => $host_data->{comment},
    duid              => $host_data->{duid},
    iaid              => $host_data->{iaid},
    flags             => $host_data->{flags},
    cdate             => $host_data->{cdate},
    cdate_str         => $host_data->{cdate_str},
    cuser             => $host_data->{cuser},
    mdate             => $host_data->{mdate},
    mdate_str         => $host_data->{mdate_str},
    muser             => $host_data->{muser},
    expiration        => $host_data->{expiration},
    card_info         => $host_data->{card_info},
  };

  $response->{alias_d}        = $host_data->{alias_d}        if exists $host_data->{alias_d};
  $response->{cname_alias}    = $host_data->{cname_alias}    if exists $host_data->{cname_alias};
  $response->{static_alias}   = $host_data->{static_alias}   if exists $host_data->{static_alias};
  $response->{wks_rec}        = $host_data->{wks_rec}        if exists $host_data->{wks_rec};
  $response->{mx_rec}         = $host_data->{mx_rec}         if exists $host_data->{mx_rec};
  $response->{grp_rec}        = $host_data->{grp_rec}        if exists $host_data->{grp_rec};

  for my $field (@ARRAY_FIELDS) {
    next if $field eq 'ip';
    if (ref $host_data->{$field} eq 'ARRAY' && @{$host_data->{$field}} > 1) {
      $response->{$field} = $FIELDS{$field}->decode($host_data->{$field});
    }
  }

  return $response;
}

# ---------------------------------------------------------------------------
# Record builders (private)
# ---------------------------------------------------------------------------

sub _build_ip_record        { [0, $_[0][0], $_[0][1], $_[0][2], 2] }
sub _build_ns_record        { [0, $_[0]->{ns},      $_[0]->{comment} // '', 2] }
sub _build_ds_record        { [0, $_[0]->{key_tag}, $_[0]->{algorithm}, $_[0]->{digest_type}, $_[0]->{digest}, $_[0]->{comment} // '', 2] }
sub _build_wks_record       { [0, $_[0]->{proto},   $_[0]->{services}, $_[0]->{comment} // '', 2] }
sub _build_printer_record   { [0, $_[0]->{printer}, $_[0]->{comment} // '', 2] }
sub _build_srv_record       { [0, $_[0]->{pri}, $_[0]->{weight}, $_[0]->{port}, $_[0]->{target}, $_[0]->{comment} // '', 2] }
sub _build_sshfp_record     { [0, $_[0]->{algorithm}, $_[0]->{hashtype}, $_[0]->{fingerprint}, $_[0]->{comment} // '', 2] }
sub _build_tlsa_record      { [0, $_[0]->{usage}, $_[0]->{selector}, $_[0]->{matching_type}, $_[0]->{association_data}, $_[0]->{comment} // '', 2] }
sub _build_alias_a_record   { [0, $_[0]->{arec}, 2] }
sub _build_subgroup_record  { [0, $_[0]->{grp}, 2] }

1;
