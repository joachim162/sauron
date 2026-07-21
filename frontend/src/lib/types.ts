export interface LoginRequest {
  email: string;
  password: string;
}

export interface LoginResponse {
  user: User;
  permissions?: Permissions;
}

export interface User {
  id: number;
  username: string;
  name: string;
  superuser: boolean;
  email: string;
  alevel: number;
  auth_method: string;
}

export interface Permissions {
  server: Record<string, string>;
  zone: Record<string, string>;
  alevel: number;
  rhf?: Record<string, number>;
}

export interface Server {
  id: number;
  name: string;
  comment?: string;
  hostname?: string;
  hostaddr?: string;
  hostmaster?: string;
  directory?: string;
  masterserver?: number;
  zones_only?: boolean;
  server_type?: string;
  [key: string]: unknown;
}

export interface Zone {
  id: number;
  server_id: number;
  name: string;
  type: string;
  reverse: boolean;
  comment?: string;
  [key: string]: unknown;
}

export interface IpEntry {
  ip: string;
  reverse: boolean;
  forward: boolean;
}

export interface Host {
  id: number;
  domain: string;
  fqdn: string;
  zone_id: number;
  server_id: number;
  server: string;
  type: number;
  ips: IpEntry[];
  ttl?: number;
  class?: string;
  grp?: number;
  ether?: string;
  info?: string;
  location?: string;
  dept?: string;
  huser?: string;
  email?: string;
  comment?: string;
  duid?: string;
  iaid?: number;
  flags?: number;
  expiration?: number;
  [key: string]: unknown;
}

export interface HostListItem {
  id: number;
  domain: string;
  type: number;
  zone_id: number;
  server_id: number;
  ips: string[];
  ttl?: number | null;
  class?: string | null;
  grp?: number | null;
  alias?: number | null;
  cname_txt?: string | null;
  hinfo_hw?: string | null;
  hinfo_sw?: string | null;
  router?: number | null;
  ether?: string | null;
  info?: string | null;
  location?: string | null;
  dept?: string | null;
  huser?: string | null;
  email?: string | null;
  model?: string | null;
  serial?: string | null;
  misc?: string | null;
  asset_id?: string | null;
  comment?: string | null;
  duid?: string | null;
  iaid?: number | null;
  cdate?: number | null;
  cuser?: string | null;
  mdate?: number | null;
  muser?: string | null;
  [key: string]: unknown;
}

export const HOST_TYPES: Record<number, string> = {
  0: "Misc",
  1: "Host",
  2: "Delegation",
  3: "MX entry",
  4: "Alias (CNAME)",
  5: "Printer",
  6: "Glue record",
  7: "Alias (AREC)",
  8: "SRV record",
  9: "DHCP-only",
  10: "Zone",
  101: "Reservation",
};

export interface DhcpEntry {
  dhcp: string;
  comment?: string;
}

export interface Net {
  id: number;
  server_id: number;
  netname: string;
  name?: string;
  net: string;
  comment?: string;
  subnet?: boolean;
  dummy?: boolean;
  vlan?: number;
  vlan_name?: string | null;
  alevel?: number;
  private_flag?: boolean;
  range_start?: string;
  range_end?: string;
  ip_policy?: number;
  no_dhcp?: boolean;
  dhcp?: boolean | null;
  dhcp_l?: DhcpEntry[];
  rp_mbox?: string;
  rp_txt?: string;
  cdate?: number;
  cuser?: string;
  mdate?: number;
  muser?: string;
  [key: string]: unknown;
}

export interface NewNet {
  netname: string;
  name: string;
  net: string;
  comment?: string;
  subnet?: boolean;
  dummy?: boolean;
  vlan?: number;
  alevel?: number;
  private_flag?: boolean;
  range_start?: string;
  range_end?: string;
  ip_policy?: number;
  no_dhcp?: boolean;
  dhcp_l?: DhcpEntry[];
  rp_mbox?: string;
  rp_txt?: string;
}

export interface UpdateNet extends Partial<NewNet> {}

export interface Group {
  id: number;
  name: string;
  comment?: string;
  [key: string]: unknown;
}

export interface Vlan {
  id: number;
  name: string;
  comment?: string;
  [key: string]: unknown;
}

export interface Acl {
  id: number;
  name: string;
  comment?: string;
  [key: string]: unknown;
}

export interface Key {
  id: number;
  name: string;
  comment?: string;
  [key: string]: unknown;
}

export interface MxTemplate {
  id: number;
  name: string;
  comment?: string;
  [key: string]: unknown;
}

export interface PaginatedResponse<T> {
  data: T[];
  metadata: {
    pagination: {
      total: number;
      page: number;
      per_page: number;
      total_pages: number;
    };
    sort: Array<{ name: string; direction: string }>;
    filters: Array<{ name: string; [key: string]: unknown }>;
  };
}

export interface ListItem {
  id: number;
  name: string;
  comment?: string;
  [key: string]: unknown;
}

export interface ApiError {
  error: string;
  message?: string;
}

export interface ApiValidationError {
  errors: Array<{ message: string; path: string }>;
  status: number;
}
