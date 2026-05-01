import { api } from "@/lib/api-client";
import type {
  LoginRequest,
  LoginResponse,
  Server,
  Zone,
  Host,
} from "@/lib/types";

// ---- Auth ----
export const authApi = {
  login: (data: LoginRequest) =>
    api.post<LoginResponse>("/auth/login", data, { noAuth: true }),
  logout: () => api.post<{ message: string }>("/auth/logout"),
  me: () => api.get<LoginResponse>("/auth/me"),
};

// ---- Servers ----
export const serversApi = {
  list: () => api.get<Server[]>("/servers"),
  get: (name: string) => api.get<Server>(`/servers/${encodeURIComponent(name)}`),
  create: (data: Partial<Server>) => api.post<Server>("/servers", data),
  update: (name: string, data: Partial<Server>) =>
    api.put<Server>(`/servers/${encodeURIComponent(name)}`, data),
  delete: (name: string) =>
    api.del(`/servers/${encodeURIComponent(name)}`),
};

// ---- Zones ----
export const zonesApi = {
  list: (serverName: string) =>
    api.get<Zone[]>(`/servers/${encodeURIComponent(serverName)}/zones`),
  get: (serverName: string, zoneName: string) =>
    api.get<Zone>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}`),
  create: (serverName: string, data: { name: string; type?: string }) =>
    api.post<Zone>(`/servers/${encodeURIComponent(serverName)}/zones`, data),
  update: (serverName: string, zoneName: string, data: Partial<Zone>) =>
    api.put<Zone>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}`, data),
  delete: (serverName: string, zoneName: string) =>
    api.del(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}`),
};

// ---- Hosts ----
export const hostsApi = {
  list: (serverName: string, zoneName: string) =>
    api.get<Host[]>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts`),
  get: (serverName: string, zoneName: string, hostname: string) =>
    api.get<Host>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts/${encodeURIComponent(hostname)}`),
  create: (serverName: string, zoneName: string, data: { hostname: string; type: number; ips?: string[]; [key: string]: unknown }) =>
    api.post<Host>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts`, data),
  update: (serverName: string, zoneName: string, hostname: string, data: Partial<Host>) =>
    api.put<Host>(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts/${encodeURIComponent(hostname)}`, data),
  delete: (serverName: string, zoneName: string, hostname: string) =>
    api.del(`/servers/${encodeURIComponent(serverName)}/zones/${encodeURIComponent(zoneName)}/hosts/${encodeURIComponent(hostname)}`),
};
