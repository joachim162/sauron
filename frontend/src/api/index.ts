import { api } from "@/lib/api-client";
import type {
  LoginRequest,
  LoginResponse,
  Server,
  Zone,
  Host,
  HostListItem,
  IpEntry,
  PaginatedResponse,
  Net,
  NewNet,
  UpdateNet,
  HostListFilters,
  Group,
  GroupSummary,
  NewGroup,
  UpdateGroup,
  GroupAssignee,
  GroupType,
  Vlan,
  VlanSummary,
  NewVlan,
  UpdateVlan,
  MxTemplateSummary,
  MxTemplate,
  NewMxTemplate,
  UpdateMxTemplate,
  WksTemplateSummary,
  WksTemplate,
  NewWksTemplate,
  UpdateWksTemplate,
  PrinterClassSummary,
  PrinterClass,
  NewPrinterClass,
  UpdatePrinterClass,
  HinfoTemplate,
  NewHinfoTemplate,
  UpdateHinfoTemplate,
  AssignableMxTemplate,
  AssignableWksTemplate,
} from "@/lib/types";

export interface PageOpts {
  page?: number;
  per_page?: number;
}

function pageParams(opts?: PageOpts): string {
  const params = new URLSearchParams();
  if (opts?.page !== undefined) params.set("page", String(opts.page));
  if (opts?.per_page !== undefined) params.set("per_page", String(opts.per_page));
  const qs = params.toString();
  return qs ? `?${qs}` : "";
}

// Fetch every page of a paginated endpoint (ADR 0004 pickers).
export async function fetchAllPages<T>(
  fetchPage: (page: number, perPage: number) => Promise<PaginatedResponse<T>>
): Promise<T[]> {
  const perPage = 100;
  const first = await fetchPage(1, perPage);
  const all = [...first.data];
  const totalPages = first.metadata.pagination.total_pages || 1;
  for (let p = 2; p <= totalPages; p++) {
    all.push(...(await fetchPage(p, perPage)).data);
  }
  return all;
}

// ---- Auth ----
export const authApi = {
  login: (data: LoginRequest) =>
    api.post<LoginResponse>("/auth/login", data, { noAuth: true }),
  logout: () => api.post<{ message: string }>("/auth/logout"),
  me: () => api.get<LoginResponse>("/auth/me"),
};

// ---- Servers ----
export const serversApi = {
  list: (opts?: PageOpts) =>
    api.get<PaginatedResponse<Server>>(`/servers${pageParams(opts)}`),
  get: (name: string) => api.get<Server>(`/servers/${encodeURIComponent(name)}`),
  create: (data: Partial<Server>) => api.post<Server>("/servers", data),
  update: (name: string, data: Partial<Server>) =>
    api.put<Server>(`/servers/${encodeURIComponent(name)}`, data),
  delete: (name: string) =>
    api.del(`/servers/${encodeURIComponent(name)}`),
};

// ---- Zones ----
export const zonesApi = {
  list: (serverName: string, opts?: PageOpts) =>
    api.get<PaginatedResponse<Zone>>(
      `/servers/${encodeURIComponent(serverName)}/zones${pageParams(opts)}`
    ),
  get: (serverName: string, zoneName: string) =>
    api.get<Zone>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}`),
  create: (serverName: string, data: { name: string; type?: string }) =>
    api.post<Zone>(`/servers/${encodeURIComponent(serverName)}/zones`, data),
  update: (serverName: string, zoneName: string, data: Partial<Zone>) =>
    api.put<Zone>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}`, data),
  delete: (serverName: string, zoneName: string) =>
    api.del(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}`),
};

// ---- Networks ----
export const netsApi = {
  list: (
    serverName: string,
    opts?: { list?: string; page?: number; per_page?: number }
  ) => {
    const params = new URLSearchParams();
    if (opts?.list) params.set("list", opts.list);
    if (opts?.page !== undefined) params.set("page", String(opts.page));
    if (opts?.per_page !== undefined) params.set("per_page", String(opts.per_page));
    const qs = params.toString();
    return api.get<PaginatedResponse<Net>>(
      `/servers/${encodeURIComponent(serverName)}/networks${qs ? `?${qs}` : ""}`
    );
  },
  get: (serverName: string, netname: string) =>
    api.get<Net>(`/servers/${encodeURIComponent(serverName)}/networks/${encodeURIComponent(netname)}`),
  create: (serverName: string, data: NewNet) =>
    api.post<Net>(`/servers/${encodeURIComponent(serverName)}/networks`, data),
  update: (serverName: string, netname: string, data: UpdateNet) =>
    api.put<Net>(`/servers/${encodeURIComponent(serverName)}/networks/${encodeURIComponent(netname)}`, data),
  delete: (serverName: string, netname: string) =>
    api.del(`/servers/${encodeURIComponent(serverName)}/networks/${encodeURIComponent(netname)}`),
  assignable: (serverName: string) =>
    api.get<Net[]>(`/servers/${encodeURIComponent(serverName)}/assignable-subnets`),
};

// ---- Host groups (ADR 0008) ----
export const groupsApi = {
  list: (
    serverName: string,
    opts?: { page?: number; per_page?: number; type?: GroupType }
  ) => {
    const params = new URLSearchParams();
    if (opts?.type) params.set("type", opts.type);
    if (opts?.page !== undefined) params.set("page", String(opts.page));
    if (opts?.per_page !== undefined) params.set("per_page", String(opts.per_page));
    const qs = params.toString();
    return api.get<PaginatedResponse<GroupSummary>>(
      `/servers/${encodeURIComponent(serverName)}/groups${qs ? `?${qs}` : ""}`
    );
  },
  get: (serverName: string, name: string) =>
    api.get<Group>(`/servers/${encodeURIComponent(serverName)}/groups/${encodeURIComponent(name)}`),
  create: (serverName: string, data: NewGroup) =>
    api.post<Group>(`/servers/${encodeURIComponent(serverName)}/groups`, data),
  update: (serverName: string, name: string, data: UpdateGroup) =>
    api.put<Group>(`/servers/${encodeURIComponent(serverName)}/groups/${encodeURIComponent(name)}`, data),
  delete: (serverName: string, name: string, reassignTo?: string) => {
    const qs = reassignTo ? `?reassign_to=${encodeURIComponent(reassignTo)}` : "";
    return api.del(`/servers/${encodeURIComponent(serverName)}/groups/${encodeURIComponent(name)}${qs}`);
  },
  assignable: (serverName: string, role: "base" | "subgroup") =>
    api.get<GroupAssignee[]>(
      `/servers/${encodeURIComponent(serverName)}/assignable-groups?role=${role}`
    ),
};

// ---- VLANs (ADR 0009) ----
export const vlansApi = {
  list: (
    serverName: string,
    opts?: { page?: number; per_page?: number }
  ) => {
    const params = new URLSearchParams();
    if (opts?.page !== undefined) params.set("page", String(opts.page));
    if (opts?.per_page !== undefined) params.set("per_page", String(opts.per_page));
    const qs = params.toString();
    return api.get<PaginatedResponse<VlanSummary>>(
      `/servers/${encodeURIComponent(serverName)}/vlans${qs ? `?${qs}` : ""}`
    );
  },
  get: (serverName: string, name: string) =>
    api.get<Vlan>(`/servers/${encodeURIComponent(serverName)}/vlans/${encodeURIComponent(name)}`),
  create: (serverName: string, data: NewVlan) =>
    api.post<Vlan>(`/servers/${encodeURIComponent(serverName)}/vlans`, data),
  update: (serverName: string, name: string, data: UpdateVlan) =>
    api.put<Vlan>(`/servers/${encodeURIComponent(serverName)}/vlans/${encodeURIComponent(name)}`, data),
  delete: (serverName: string, name: string) =>
    api.del(`/servers/${encodeURIComponent(serverName)}/vlans/${encodeURIComponent(name)}`),
  // Complete list for pickers (net form).
  all: (serverName: string) =>
    fetchAllPages<VlanSummary>((page, per_page) => vlansApi.list(serverName, { page, per_page })),
};

// ---- Templates (ADR 0010) ----

export const mxTemplatesApi = {
  list: (
    serverName: string,
    zoneName: string,
    opts?: { page?: number; per_page?: number }
  ) =>
    api.get<PaginatedResponse<MxTemplateSummary>>(
      `/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/mx-templates${pageParams(opts)}`
    ),
  get: (serverName: string, zoneName: string, id: number) =>
    api.get<MxTemplate>(
      `/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/mx-templates/${id}`
    ),
  create: (serverName: string, zoneName: string, data: NewMxTemplate) =>
    api.post<MxTemplate>(
      `/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/mx-templates`,
      data
    ),
  update: (serverName: string, zoneName: string, id: number, data: UpdateMxTemplate) =>
    api.put<MxTemplate>(
      `/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/mx-templates/${id}`,
      data
    ),
  delete: (serverName: string, zoneName: string, id: number, reassignTo?: number) => {
    const qs = reassignTo ? `?reassign_to=${reassignTo}` : "";
    return api.del(
      `/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/mx-templates/${id}${qs}`
    );
  },
  assignable: (serverName: string, zoneName: string) =>
    api.get<AssignableMxTemplate[]>(
      `/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/assignable-mx-templates`
    ),
};

export const wksTemplatesApi = {
  list: (
    serverName: string,
    opts?: { page?: number; per_page?: number }
  ) =>
    api.get<PaginatedResponse<WksTemplateSummary>>(
      `/servers/${encodeURIComponent(serverName)}/wks-templates${pageParams(opts)}`
    ),
  get: (serverName: string, id: number) =>
    api.get<WksTemplate>(`/servers/${encodeURIComponent(serverName)}/wks-templates/${id}`),
  create: (serverName: string, data: NewWksTemplate) =>
    api.post<WksTemplate>(`/servers/${encodeURIComponent(serverName)}/wks-templates`, data),
  update: (serverName: string, id: number, data: UpdateWksTemplate) =>
    api.put<WksTemplate>(`/servers/${encodeURIComponent(serverName)}/wks-templates/${id}`, data),
  delete: (serverName: string, id: number, reassignTo?: number) => {
    const qs = reassignTo ? `?reassign_to=${reassignTo}` : "";
    return api.del(`/servers/${encodeURIComponent(serverName)}/wks-templates/${id}${qs}`);
  },
  assignable: (serverName: string) =>
    api.get<AssignableWksTemplate[]>(
      `/servers/${encodeURIComponent(serverName)}/assignable-wks-templates`
    ),
};

export const printerClassesApi = {
  list: (opts?: { page?: number; per_page?: number }) =>
    api.get<PaginatedResponse<PrinterClassSummary>>(`/printer-classes${pageParams(opts)}`),
  get: (id: number) => api.get<PrinterClass>(`/printer-classes/${id}`),
  create: (data: NewPrinterClass) => api.post<PrinterClass>("/printer-classes", data),
  update: (id: number, data: UpdatePrinterClass) =>
    api.put<PrinterClass>(`/printer-classes/${id}`, data),
  delete: (id: number) => api.del(`/printer-classes/${id}`),
};

export const hinfoTemplatesApi = {
  list: (opts?: { page?: number; per_page?: number }) =>
    api.get<PaginatedResponse<HinfoTemplate>>(`/hinfo-templates${pageParams(opts)}`),
  get: (id: number) => api.get<HinfoTemplate>(`/hinfo-templates/${id}`),
  create: (data: NewHinfoTemplate) => api.post<HinfoTemplate>("/hinfo-templates", data),
  update: (id: number, data: UpdateHinfoTemplate) =>
    api.put<HinfoTemplate>(`/hinfo-templates/${id}`, data),
  delete: (id: number) => api.del(`/hinfo-templates/${id}`),
};

// ---- Hosts ----
export const hostsApi = {
  list: (
    serverName: string,
    zoneName: string,
    opts?: { page?: number; per_page?: number; filters?: HostListFilters }
  ) => {
    const params = new URLSearchParams();
    if (opts?.page !== undefined) params.set("page", String(opts.page));
    if (opts?.per_page !== undefined) params.set("per_page", String(opts.per_page));
    for (const [key, value] of Object.entries(opts?.filters ?? {})) {
      if (value) params.set(key, value);
    }
    const qs = params.toString();
    return api.get<PaginatedResponse<HostListItem>>(
      `/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts${qs ? `?${qs}` : ""}`
    );
  },
  get: (serverName: string, zoneName: string, hostname: string) =>
    api.get<Host>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts/${encodeURIComponent(hostname)}`),
  create: (serverName: string, zoneName: string, data: { hostname: string; type: string; ips?: IpEntry[]; [key: string]: unknown }) =>
    api.post<Host>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts`, data),
  update: (serverName: string, zoneName: string, hostname: string, data: Partial<Host>) =>
    api.put<Host>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts/${encodeURIComponent(hostname)}`, data),
  delete: (serverName: string, zoneName: string, hostname: string) =>
    api.del(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts/${encodeURIComponent(hostname)}`),
  copy: (serverName: string, zoneName: string, hostname: string, data?: Record<string, unknown>) =>
    api.post<Host>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts/${encodeURIComponent(hostname)}/copies`, data ?? {}),
  move: (serverName: string, zoneName: string, hostname: string, data: { ip?: string; net?: string; from_ip?: string; zone?: string }) =>
    api.post<Host>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts/${encodeURIComponent(hostname)}/move`, data),
};
