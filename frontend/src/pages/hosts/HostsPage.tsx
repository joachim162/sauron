import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import type { ColumnDef } from "@tanstack/react-table";
import { hostsApi } from "@/api";
import type { Host } from "@/lib/types";
import { HOST_TYPES } from "@/lib/types";
import { useServerContext } from "@/hooks/use-server-context";
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
import { useState } from "react";

export default function HostsPage() {
  const { serverName, zoneId, zoneName } = useServerContext();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const [createOpen, setCreateOpen] = useState(false);
  const [selectedType, setSelectedType] = useState("1");
  const [typeTouched, setTypeTouched] = useState(false);
  const [deleteHostname, setDeleteHostname] = useState<string | null>(null);

  const HOST_CREATE_FIELDS: Record<number, {
    inputs: Array<{ key: string; label: string; placeholder: string }>;
    toPayload: (fd: FormData) => Record<string, unknown>;
  }> = {
    1: {
      inputs: [{ key: "ips", label: "IP Address", placeholder: "192.168.1.10" }],
      toPayload: (fd) => { const v = fd.get("ips") as string; return v ? { ips: [v] } : {}; },
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
      toPayload: (fd) => { const v = fd.get("ips") as string; return v ? { ips: [v] } : {}; },
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
        const i = fd.get("ips") as string; if (i) p.ips = [i];
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
        const i = fd.get("ips") as string; if (i) p.ips = [i];
        return p;
      },
    },
  };

  // List hosts in zone
  const { data: hosts, isLoading } = useQuery({
    queryKey: ["hosts", serverName, zoneName],
    queryFn: () => hostsApi.list(serverName!, zoneName!),
    enabled: !!serverName && !!zoneName,
  });

  const deleteMutation = useMutation({
    mutationFn: (hostname: string) => hostsApi.delete(serverName!, zoneName!, hostname),
    onSuccess: () => {
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

  const columns: ColumnDef<Host>[] = [
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
      accessorKey: "ip",
      header: "IP",
      cell: ({ getValue }) => (
        <span className="font-mono text-sm">{(getValue() as string) || "—"}</span>
      ),
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
              ? `${zoneName} — ${(hosts as Host[] || []).length} hosts`
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
        <DataTable
          columns={columns}
          data={(hosts as Host[]) || []}
          isLoading={isLoading}
          emptyMessage="No hosts in this zone."
          onRowClick={(host) => navigate(`/hosts/${encodeURIComponent(host.domain)}`)}
        />
      )}

      {!zoneId && (
        <div className="rounded-lg border p-8 text-center text-muted-foreground">
          Select a zone from the Zones page, or use the search bar above.
        </div>
      )}

      {/* Create dialog */}
      {createOpen && (
        <Dialog open={createOpen} onOpenChange={() => setCreateOpen(false)}>
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
                if (cfg) Object.assign(payload, cfg.toPayload(fd));
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
                <Select name="type" defaultValue="1" onValueChange={(v) => { setSelectedType(v); setTypeTouched(true); }}>
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
              {typeTouched && HOST_CREATE_FIELDS[Number(selectedType)]?.inputs.map((field) => (
                <div className="space-y-2" key={field.key}>
                  <Label htmlFor={field.key}>{field.label}</Label>
                  <Input id={field.key} name={field.key} placeholder={field.placeholder} />
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
