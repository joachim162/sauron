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

export interface Host {
  id: number;
  domain: string;
  fqdn: string;
  zone_id: number;
  server_id: number;
  server: string;
  type: number;
  ips: string[];
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

export interface Net {
  id: number;
  name: string;
  comment?: string;
  [key: string]: unknown;
}

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
  pagination: {
    page: number;
    per_page: number;
    total: number;
    total_pages: number;
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
