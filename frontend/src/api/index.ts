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

// ---- Hosts ----
export const hostsApi = {
  list: (serverName: string, zoneName: string, opts?: { page?: number; per_page?: number }) => {
    const params = new URLSearchParams();
    if (opts?.page !== undefined) params.set("page", String(opts.page));
    if (opts?.per_page !== undefined) params.set("per_page", String(opts.per_page));
    const qs = params.toString();
    return api.get<PaginatedResponse<HostListItem>>(
      `/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts${qs ? `?${qs}` : ""}`
    );
  },
  get: (serverName: string, zoneName: string, hostname: string) =>
    api.get<Host>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts/${encodeURIComponent(hostname)}`),
  create: (serverName: string, zoneName: string, data: { hostname: string; type: number; ips?: IpEntry[]; [key: string]: unknown }) =>
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
