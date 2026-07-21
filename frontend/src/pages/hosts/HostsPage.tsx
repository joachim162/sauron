import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useSearchParams } from "react-router-dom";
import type { ColumnDef, PaginationState } from "@tanstack/react-table";
import { useEffect, useMemo, useRef, useState } from "react";
import { hostsApi, netsApi } from "@/api";
import type { HostListItem } from "@/lib/types";
import { HOST_TYPES } from "@/lib/types";
import { useServerContext } from "@/hooks/use-server-context";
import { useAuth } from "@/hooks/use-auth";
import { DataTable } from "@/components/DataTable";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  DialogDescription,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Plus, Trash2, Loader2, AlertCircle } from "lucide-react";
import { ApiRequestError } from "@/lib/api-client";

const PAGE_SIZE_OPTIONS = [10, 25, 50, 100];

const RHF_LABELS: Record<string, string> = {
  huser: "User",
  dept: "Dept.",
  location: "Location",
  info: "[Extra] Info",
  ether: "MAC Address",
  duid: "DUID",
  asset_id: "Asset ID",
  model: "Model",
  serial: "Serial no.",
  misc: "Misc.",
  email: "User Email",
};

export default function HostsPage() {
  const { serverName, zoneId, zoneName } = useServerContext();
  const { permissions } = useAuth();
  const rhf = permissions?.rhf ?? {};
  const rhfRequired = Object.entries(rhf).filter(([, v]) => v === 0).map(([k]) => k);
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const [createOpen, setCreateOpen] = useState(false);
  const [selectedType, setSelectedType] = useState("1");
  const [typeTouched, setTypeTouched] = useState(false);
  const [deleteHostname, setDeleteHostname] = useState<string | null>(null);
  const [selectedNet, setSelectedNet] = useState("manual");
  const [searchParams, setSearchParams] = useSearchParams();
  const pagination = useMemo<PaginationState>(() => {
    const page = Math.max(1, parseInt(searchParams.get("page") || "1", 10) || 1);
    const perPageRaw = parseInt(searchParams.get("per_page") || "50", 10) || 50;
    const perPage = Math.min(100, Math.max(1, perPageRaw));
    return { pageIndex: page - 1, pageSize: perPage };
  }, [searchParams]);

  const updatePagination = (next: PaginationState) => {
    setSearchParams(
      (prev) => {
        const params = new URLSearchParams(prev);
        params.set("page", String(next.pageIndex + 1));
        params.set("per_page", String(next.pageSize));
        return params;
      },
      { replace: true }
    );
  };

  const prevZoneRef = useRef<string | null>(zoneName);
  useEffect(() => {
    if (prevZoneRef.current === zoneName) return;
    prevZoneRef.current = zoneName;
    setSearchParams(
      (prev) => {
        const current = prev.get("page");
        if (!current || current === "1") return prev;
        const params = new URLSearchParams(prev);
        params.set("page", "1");
        return params;
      },
      { replace: true }
    );
  }, [zoneName, setSearchParams]);

  const needsNet = ["1", "101"].includes(selectedType);

  const { data: assignableNets } = useQuery({
    queryKey: ["assignable-subnets", serverName],
    queryFn: () => netsApi.assignable(serverName!),
    enabled: !!serverName && createOpen && needsNet,
  });

  const HOST_CREATE_FIELDS: Record<number, {
    inputs: Array<{ key: string; label: string; placeholder: string }>;
    toPayload: (fd: FormData) => Record<string, unknown>;
  }> = {
    1: {
      inputs: [{ key: "ips", label: "IP Address", placeholder: "192.168.1.10" }],
      toPayload: (fd) => { const v = fd.get("ips") as string; return v ? { ips: [{ ip: v }] } : {}; },
    },
    2: {
      inputs: [{ key: "ns", label: "NS Server", placeholder: "ns1.example.com" }],
      toPayload: (fd) => { const v = fd.get("ns") as string; return v ? { ns_l: [{ ns: v, comment: "" }] } : {}; },
    },
    3: {
      inputs: [
        { key: "pri", label: "Priority", placeholder: "10" },
        { key: "mx", label: "MX Target", placeholder: "mail.example.com" },
      ],
      toPayload: (fd) => {
        const pri = fd.get("pri") as string;
        const mx = fd.get("mx") as string;
        return (pri && mx) ? { mx_l: [{ pri: Number(pri), mx, comment: "" }] } : {};
      },
    },
    4: {
      inputs: [{ key: "cname_txt", label: "CNAME Target", placeholder: "target.example.com." }],
      toPayload: (fd) => { const v = fd.get("cname_txt") as string; return v ? { cname_txt: v } : {}; },
    },
    5: {
      inputs: [{ key: "printer", label: "Printer Name", placeholder: "printer-name" }],
      toPayload: (fd) => { const v = fd.get("printer") as string; return v ? { printer_l: [{ printer: v, comment: "" }] } : {}; },
    },
    6: {
      inputs: [{ key: "ips", label: "IP Address", placeholder: "192.168.1.10" }],
      toPayload: (fd) => { const v = fd.get("ips") as string; return v ? { ips: [{ ip: v }] } : {}; },
    },
    7: {
      inputs: [{ key: "arec", label: "AREC Target", placeholder: "192.168.1.10" }],
      toPayload: (fd) => { const v = fd.get("arec") as string; return v ? { alias_a: [{ arec: v }] } : {}; },
    },
    8: {
      inputs: [
        { key: "pri", label: "Priority", placeholder: "0" },
        { key: "weight", label: "Weight", placeholder: "100" },
        { key: "port", label: "Port", placeholder: "5060" },
        { key: "target", label: "Target", placeholder: "sip.example.com" },
      ],
      toPayload: (fd) => {
        const pri = fd.get("pri") as string;
        const weight = fd.get("weight") as string;
        const port = fd.get("port") as string;
        const target = fd.get("target") as string;
        return (pri && weight && port && target)
          ? { srv_l: [{ pri: Number(pri), weight: Number(weight), port: Number(port), target, comment: "" }] }
          : {};
      },
    },
    9: {
      inputs: [
        { key: "ether", label: "MAC Address", placeholder: "aa:bb:cc:dd:ee:ff" },
        { key: "ips", label: "IP Address", placeholder: "192.168.1.10" },
      ],
      toPayload: (fd) => {
        const p: Record<string, unknown> = {};
        const e = fd.get("ether") as string; if (e) p.ether = e;
        const i = fd.get("ips") as string; if (i) p.ips = [{ ip: i }];
        return p;
      },
    },
    11: {
      inputs: [
        { key: "algorithm", label: "Algorithm", placeholder: "1" },
        { key: "hashtype", label: "Hash Type", placeholder: "1" },
        { key: "fingerprint", label: "Fingerprint", placeholder: "" },
      ],
      toPayload: (fd) => {
        const a = fd.get("algorithm") as string;
        const h = fd.get("hashtype") as string;
        const f = fd.get("fingerprint") as string;
        return (a && h && f)
          ? { sshfp_l: [{ algorithm: Number(a), hashtype: Number(h), fingerprint: f, comment: "" }] }
          : {};
      },
    },
    12: {
      inputs: [
        { key: "usage", label: "Usage", placeholder: "0" },
        { key: "selector", label: "Selector", placeholder: "0" },
        { key: "matching_type", label: "Matching Type", placeholder: "0" },
        { key: "association_data", label: "Association Data", placeholder: "" },
      ],
      toPayload: (fd) => {
        const u = fd.get("usage") as string;
        const s = fd.get("selector") as string;
        const m = fd.get("matching_type") as string;
        const a = fd.get("association_data") as string;
        return (u && s && m && a)
          ? { tlsa_l: [{ usage: Number(u), selector: Number(s), matching_type: Number(m), association_data: a, comment: "" }] }
          : {};
      },
    },
    13: {
      inputs: [{ key: "txt", label: "TXT Value", placeholder: "v=spf1 ..." }],
      toPayload: (fd) => { const v = fd.get("txt") as string; return v ? { txt_l: [{ txt: v, comment: "" }] } : {}; },
    },
    101: {
      inputs: [
        { key: "ether", label: "MAC Address", placeholder: "aa:bb:cc:dd:ee:ff" },
        { key: "ips", label: "IP Address", placeholder: "192.168.1.10" },
      ],
      toPayload: (fd) => {
        const p: Record<string, unknown> = {};
        const e = fd.get("ether") as string; if (e) p.ether = e;
        const i = fd.get("ips") as string; if (i) p.ips = [{ ip: i }];
        return p;
      },
    },
  };

  // List hosts in zone
  const { data: hostsResponse, isLoading } = useQuery({
    queryKey: ["hosts", serverName, zoneName, pagination.pageIndex, pagination.pageSize],
    queryFn: () =>
      hostsApi.list(serverName!, zoneName!, {
        page: pagination.pageIndex + 1,
        per_page: pagination.pageSize,
      }),
    enabled: !!serverName && !!zoneName,
  });

  const hosts = hostsResponse?.data ?? [];
  const totalHosts = hostsResponse?.metadata.pagination.total ?? hosts.length;
  const pageCount = hostsResponse?.metadata.pagination.total_pages ?? 1;
  const pageSizeOptions = PAGE_SIZE_OPTIONS.includes(pagination.pageSize)
    ? PAGE_SIZE_OPTIONS
    : [...PAGE_SIZE_OPTIONS, pagination.pageSize].sort((a, b) => a - b);

  const deleteMutation = useMutation({
    mutationFn: (hostname: string) => hostsApi.delete(serverName!, zoneName!, hostname),
    onSuccess: () => {
      if (hosts.length === 1 && pagination.pageIndex > 0) {
        updatePagination({ ...pagination, pageIndex: pagination.pageIndex - 1 });
      }
      queryClient.invalidateQueries({ queryKey: ["hosts"] });
      setDeleteHostname(null);
    },
  });

  const createMutation = useMutation({
    mutationFn: (data: { hostname: string; type: number; [key: string]: unknown }) =>
      hostsApi.create(serverName!, zoneName!, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["hosts"] });
      setCreateOpen(false);
    },
  });

  if (!serverName) {
    return (
      <div className="flex flex-col items-center justify-center py-12 text-center">
        <AlertCircle className="h-12 w-12 text-muted-foreground mb-4" />
        <h2 className="text-xl font-semibold">No Server Selected</h2>
        <p className="text-muted-foreground mt-1 mb-4">Select a server first.</p>
        <Button onClick={() => navigate("/")}>Go to Dashboard</Button>
      </div>
    );
  }

  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
  };

  const columns: ColumnDef<HostListItem>[] = [
    { accessorKey: "id", header: "ID", size: 60 },
    {
      accessorKey: "domain",
      header: "Domain",
      cell: ({ getValue }) => (
        <span className="font-mono text-sm">{getValue() as string}</span>
      ),
    },
    {
      accessorKey: "type",
      header: "Type",
      cell: ({ getValue }) => {
        const t = getValue() as number;
        return (
          <Badge variant="outline" className="text-xs">
            {HOST_TYPES[t] || `Type ${t}`}
          </Badge>
        );
      },
    },
    {
      accessorKey: "ips",
      header: "IP",
      cell: ({ getValue }) => {
        const v = getValue() as string[] | undefined;
        return v && v.length > 0 ? (
          <span className="font-mono text-sm">{v.join(", ")}</span>
        ) : (
          <span className="text-muted-foreground">—</span>
        );
      },
    },
    {
      accessorKey: "ether",
      header: "MAC",
      cell: ({ getValue }) => {
        const v = getValue() as string;
        return v ? <span className="font-mono text-xs">{v}</span> : "—";
      },
    },
    {
      id: "actions",
      header: "",
      cell: ({ row }) => (
        <div className="flex items-center gap-1 justify-end">
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              navigate(`/hosts/${encodeURIComponent(row.original.domain)}`);
            }}
          >
            Detail
          </Button>
          <Button
            variant="ghost"
            size="icon"
            className="h-8 w-8 text-destructive"
              onClick={(e) => {
                e.stopPropagation();
                setDeleteHostname(row.original.domain);
              }}
            title="Delete"
          >
            <Trash2 className="h-4 w-4" />
          </Button>
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Hosts</h1>
          <p className="text-muted-foreground">
            {zoneName
              ? `${zoneName} — ${totalHosts} hosts`
              : `${serverName} — Select a zone`}
          </p>
        </div>
        {zoneId && (
          <Button onClick={() => setCreateOpen(true)}>
            <Plus className="mr-2 h-4 w-4" />
            Add Host
          </Button>
        )}
      </div>

      {/* Search bar — disabled until search API is available */}
      <form onSubmit={handleSearch} className="flex gap-2">
        <div className="relative flex-1">
          <Input
            value=""
            readOnly
            placeholder="Search coming soon..."
            className="pl-9 opacity-50"
          />
        </div>
        <Button type="submit" variant="secondary" disabled>
          Search
        </Button>
      </form>

      {/* Results */}
      {zoneId && (
        <div className="space-y-2">
          <div className="flex items-center justify-end gap-2">
            <span className="text-sm text-muted-foreground">Rows per page</span>
            <Select
              value={String(pagination.pageSize)}
              onValueChange={(v) =>
                updatePagination({ pageIndex: 0, pageSize: Number(v) })
              }
            >
              <SelectTrigger className="w-24 h-8">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {pageSizeOptions.map((size) => (
                  <SelectItem key={size} value={String(size)}>
                    {size}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <DataTable
            columns={columns}
            data={hosts}
            isLoading={isLoading}
            pageCount={pageCount}
            pagination={pagination}
            onPaginationChange={updatePagination}
            emptyMessage="No hosts in this zone."
            onRowClick={(host) => navigate(`/hosts/${encodeURIComponent(host.domain)}`)}
          />
        </div>
      )}

      {!zoneId && (
        <div className="rounded-lg border p-8 text-center text-muted-foreground">
          Select a zone from the Zones page, or use the search bar above.
        </div>
      )}

      {/* Create dialog */}
      {createOpen && (
        <Dialog open={createOpen} onOpenChange={(open) => { if (!open) setCreateOpen(false); }}>
          <DialogContent className="max-w-lg">
            <DialogHeader>
              <DialogTitle>New Host</DialogTitle>
              <DialogDescription>Add a host to {zoneName}.</DialogDescription>
            </DialogHeader>
            <form
              onSubmit={(e) => {
                e.preventDefault();
                const fd = new FormData(e.currentTarget);
                const type = Number(fd.get("type"));
                const payload: { hostname: string; type: number; [key: string]: unknown } = {
                  hostname: fd.get("domain") as string,
                  type,
                };
                const cfg = HOST_CREATE_FIELDS[type];
                if (type === 1 || type === 101) {
                  if (selectedNet !== "manual") {
                    payload.net = selectedNet;
                    const ether = (fd.get("ether") as string) || "";
                    if (ether) payload.ether = ether;
                  } else {
                    const ips = (fd.get("ips") as string) || "";
                    if (ips) payload.ips = [{ ip: ips }];
                  }
                } else if (cfg) {
                  Object.assign(payload, cfg.toPayload(fd));
                }
                for (const key of rhfRequired) {
                  const v = fd.get(key) as string;
                  if (v) payload[key] = v;
                }
                createMutation.mutate(payload);
              }}
              className="space-y-4"
            >
              <div className="space-y-2">
                <Label htmlFor="domain">Domain</Label>
                <Input id="domain" name="domain" placeholder="server1" required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="type">Type</Label>
                <Select name="type" defaultValue="1" onValueChange={(v) => { setSelectedType(v); setTypeTouched(true); setSelectedNet("manual"); }}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {Object.entries(HOST_TYPES).map(([val, label]) => (
                      <SelectItem key={val} value={val}>
                        {label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              {needsNet && (
                <div className="space-y-2">
                  <Label htmlFor="net">Subnet</Label>
                  <Select
                    value={selectedNet}
                    onValueChange={(v) => setSelectedNet(v)}
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="manual">Manual IP</SelectItem>
                      {assignableNets?.map((n) => (
                        <SelectItem key={n.net} value={n.net}>
                          {n.net} - {n.name || ""}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              )}
              {needsNet && selectedNet === "manual" && (
                <div className="space-y-2">
                  <Label htmlFor="ips">IP Address</Label>
                  <Input id="ips" name="ips" placeholder="192.168.1.10" />
                </div>
              )}
              {needsNet && selectedType === "101" && (
                <div className="space-y-2">
                  <Label htmlFor="ether">MAC Address</Label>
                  <Input id="ether" name="ether" placeholder="aa:bb:cc:dd:ee:ff" />
                </div>
              )}
              {typeTouched && !needsNet && HOST_CREATE_FIELDS[Number(selectedType)]?.inputs.map((field) => (
                <div className="space-y-2" key={field.key}>
                  <Label htmlFor={field.key}>{field.label}</Label>
                  <Input id={field.key} name={field.key} placeholder={field.placeholder} />
                </div>
              ))}
              {rhfRequired.map((key) => (
                <div className="space-y-2" key={key}>
                  <Label htmlFor={key}>
                    {RHF_LABELS[key] || key}
                    <span className="text-destructive font-bold ml-1">*</span>
                  </Label>
                  <Input id={key} name={key} />
                </div>
              ))}
              <DialogFooter>
                <Button type="button" variant="outline" onClick={() => setCreateOpen(false)}>
                  Cancel
                </Button>
                <Button type="submit" disabled={createMutation.isPending}>
                  {createMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Create
                </Button>
              </DialogFooter>
              {createMutation.isError && (
                <p className="text-sm text-destructive">
                  {createMutation.error instanceof ApiRequestError
                    ? createMutation.error.data.message || createMutation.error.message
                    : "Failed to create host."}
                </p>
              )}
            </form>
          </DialogContent>
        </Dialog>
      )}

      {/* Delete dialog */}
      <Dialog open={deleteHostname !== null} onOpenChange={() => setDeleteHostname(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete Host</DialogTitle>
            <DialogDescription>Are you sure you want to delete this host?</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteHostname(null)}>Cancel</Button>
            <Button
              variant="destructive"
              onClick={() => deleteHostname && deleteMutation.mutate(deleteHostname)}
              disabled={deleteMutation.isPending}
            >
              {deleteMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
