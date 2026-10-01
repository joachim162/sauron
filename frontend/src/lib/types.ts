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
  tmplmask?: string[];
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
  expiration?: number | null;
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
  type: string;
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
  type: string;
  zone_id: number;
  server_id: number;
  fqdn?: string;
  host_group?: string | null;
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

export const HOST_TYPES: Record<string, string> = {
  misc: "Misc",
  host: "Host",
  delegation: "Delegation",
  mx: "Plain MX",
  alias: "Alias (CNAME)",
  printer: "Printer",
  glue: "Glue record",
  alias_arec: "Alias (AREC)",
  srv: "SRV record",
  dhcp_only: "DHCP-only",
  zone: "Zone",
  sshfp: "SSHFP",
  tlsa: "TLSA",
  txt: "TXT",
  naptr: "NAPTR",
  caa: "CAA",
  reservation: "Reservation",
};

export interface DhcpEntry {
  dhcp: string;
  comment?: string;
}

// Host list query filters (ADR 0007). Regex filters are PostgreSQL ARE
// syntax, case-insensitive; max length 40 (txt: 80).
export interface HostListFilters {
  q?: string;
  domain?: string;
  type?: string;
  ip?: string;
  group?: string;
  txt?: string;
  mx?: string;
  ether?: string;
  duid?: string;
  iaid?: string;
  info?: string;
  huser?: string;
  location?: string;
  dept?: string;
  model?: string;
  serial?: string;
  misc?: string;
  asset_id?: string;
  hinfo?: string;
  dhcp_date_from?: string;
  dhcp_date_to?: string;
  dhcp_last_from?: string;
  dhcp_last_to?: string;
  cdate_from?: string;
  cdate_to?: string;
  mdate_from?: string;
  mdate_to?: string;
  expiration_from?: string;
  expiration_to?: string;
  sort?: string;
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

export interface PrinterEntry {
  printer: string;
  comment?: string;
}

// ---- Host groups (ADR 0008) ----

export type GroupType =
  | "normal"
  | "dynamic_pool"
  | "dhcp_class"
  | "custom_dhcp_class";

export const GROUP_TYPES: Record<GroupType, string> = {
  normal: "Normal",
  dynamic_pool: "Dynamic Address Pool",
  dhcp_class: "DHCP class",
  custom_dhcp_class: "Custom DHCP class",
};

// Lightweight item returned by the list endpoint.
export interface GroupSummary {
  id: number;
  server_id: number;
  name: string;
  type: GroupType;
  alevel: number;
  comment: string;
  vmps: number | null;
}

// Full record returned by the detail endpoint.
export interface Group extends GroupSummary {
  vmps_name: string | null;
  dhcp_l: DhcpEntry[];
  dhcp_l6: DhcpEntry[];
  printer_l: PrinterEntry[];
  cdate?: number | null;
  cuser?: string | null;
  mdate?: number | null;
  muser?: string | null;
}

export interface NewGroup {
  name: string;
  type?: GroupType;
  alevel?: number;
  vmps?: number | null;
  comment?: string;
  dhcp_l?: DhcpEntry[];
  dhcp_l6?: DhcpEntry[];
  printer_l?: PrinterEntry[];
}

export interface UpdateGroup extends Partial<NewGroup> {}

// Minimal item returned by the assignable-groups picker.
export interface GroupAssignee {
  id: number;
  name: string;
  type: GroupType;
}

// ---- VLANs (ADR 0009) ----

export interface VlanSummary {
  id: number;
  server_id: number;
  name: string;
  vlanno: number | null;
  description: string | null;
  comment: string | null;
}

export interface Vlan extends VlanSummary {
  dhcp_l: DhcpEntry[];
  dhcp_l6: DhcpEntry[];
  cdate?: number | null;
  cuser?: string | null;
  mdate?: number | null;
  muser?: string | null;
}

export interface NewVlan {
  name: string;
  vlanno?: number | null;
  description?: string | null;
  comment?: string | null;
  dhcp_l?: DhcpEntry[];
  dhcp_l6?: DhcpEntry[];
}

export interface UpdateVlan extends Partial<NewVlan> {}

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

// ---- Templates (ADR 0010) ----

export type HinfoType = "hardware" | "software";

export interface TemplateAudit {
  cdate?: number | null;
  cuser?: string | null;
  mdate?: number | null;
  muser?: string | null;
  cdate_str?: string | null;
  mdate_str?: string | null;
}

export interface MxEntry {
  pri: number;
  mx: string;
  comment?: string | null;
}

export interface WksEntry {
  proto: string;
  services?: string | null;
  comment?: string | null;
}

export interface MxTemplateSummary extends TemplateAudit {
  id: number;
  zone_id: number;
  name: string;
  comment?: string | null;
  alevel: number;
}

export interface MxTemplate extends MxTemplateSummary {
  mx_l: MxEntry[];
  host_count: number;
}

export interface NewMxTemplate {
  name: string;
  comment?: string | null;
  alevel?: number;
  mx_l?: MxEntry[];
}

export type UpdateMxTemplate = Partial<NewMxTemplate>;

export interface WksTemplateSummary extends TemplateAudit {
  id: number;
  server_id: number;
  name: string;
  comment?: string | null;
  alevel: number;
}

export interface WksTemplate extends WksTemplateSummary {
  wks_l: WksEntry[];
  host_count: number;
}

export interface NewWksTemplate {
  name: string;
  comment?: string | null;
  alevel?: number;
  wks_l?: WksEntry[];
}

export type UpdateWksTemplate = Partial<NewWksTemplate>;

export interface PrinterClassSummary extends TemplateAudit {
  id: number;
  name: string;
  comment?: string | null;
}

export interface PrinterClass extends PrinterClassSummary {
  printer_l: PrinterEntry[];
}

export interface NewPrinterClass {
  name: string;
  comment?: string | null;
  printer_l?: PrinterEntry[];
}

export type UpdatePrinterClass = Partial<NewPrinterClass>;

export interface HinfoTemplate extends TemplateAudit {
  id: number;
  hinfo: string;
  type: HinfoType;
  pri: number;
}

export interface NewHinfoTemplate {
  hinfo: string;
  type?: HinfoType;
  pri?: number;
}

export type UpdateHinfoTemplate = Partial<NewHinfoTemplate>;

export interface AssignableMxTemplate {
  id: number;
  name: string;
  alevel: number;
}

export interface AssignableWksTemplate {
  id: number;
  name: string;
  alevel: number;
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
