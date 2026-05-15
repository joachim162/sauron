import { useParams, useNavigate } from "react-router-dom";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { hostsApi } from "@/api";
import type { Host } from "@/lib/types";
import { HOST_TYPES } from "@/lib/types";
import { useServerContext } from "@/hooks/use-server-context";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { Separator } from "@/components/ui/separator";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { ArrowLeft, Save, Loader2, Trash2, Pencil, X, MoreHorizontal, Copy, Link, Ban, Plus } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  DialogDescription,
} from "@/components/ui/dialog";
import { useState, useCallback } from "react";

/* ── helpers ─────────────────────────────────────────── */

/** Extract data rows from BackEnd arrays (skip header row at [0]). */
function dataRows(arr: unknown): unknown[][] {
  if (!Array.isArray(arr) || arr.length <= 1) return [];
  return arr.slice(1) as unknown[][];
}

/** Parse cdate_str / mdate_str — strip HTML, extract pending flag. */
function parseDateStr(raw: unknown): { text: string; pending: boolean } {
  if (!raw || typeof raw !== "string") return { text: "—", pending: false };
  const pending = /PENDING/i.test(raw);
  const text = raw.replace(/<[^>]*>/g, "").trim();
  return { text: text || "—", pending };
}

/** Read-only field display */
function Field({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div>
      <div className="text-muted-foreground text-xs">{label}</div>
      <div className={`font-medium text-sm ${mono ? "font-mono" : ""}`}>{value || "—"}</div>
    </div>
  );
}

/* ── Editable-row types for array fields ─────────────── */

type ERow = {
  _dbId: number;       // existing DB id, 0 for new
  _deleted: boolean;
  values: string[];    // field values (without id/mode)
};

/** Convert BackEnd array rows to ERow[]. Row format: [id, val1, val2, ..., modeFlag] */
function toERows(raw: unknown[][]): ERow[] {
  // slice(1, -1) strips the DB id (first) and the mode flag (last)
  // that get_array_field always appends.
  return raw.map((r) => ({
    _dbId: Number(r[0]) || 0,
    _deleted: false,
    values: r.slice(1, -1).map((v) => String(v ?? "")),
  }));
}

/* ── inline editable table ────────────────────────────── */

function EditableArrayCard({
  title,
  columns,
  rows,
  setRows,
  editing,
  mono = [0],
}: {
  title: string;
  columns: string[];
  rows: ERow[];
  setRows: (r: ERow[]) => void;
  editing: boolean;
  mono?: number[];
}) {
  const visibleRows = rows.filter((r) => !r._deleted);
  const showCard = editing || visibleRows.length > 0;
  if (!showCard) return null;

  const updateCell = (idx: number, col: number, val: string) => {
    const next = [...rows];
    const realIdx = rows.indexOf(visibleRows[idx]);
    next[realIdx] = { ...next[realIdx], values: [...next[realIdx].values] };
    next[realIdx].values[col] = val;
    setRows(next);
  };

  const removeRow = (idx: number) => {
    const next = [...rows];
    const realIdx = rows.indexOf(visibleRows[idx]);
    next[realIdx] = { ...next[realIdx], _deleted: true };
    setRows(next);
  };

  const addRow = () => {
    setRows([...rows, { _dbId: 0, _deleted: false, values: columns.map(() => "") }]);
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">{title}</CardTitle>
      </CardHeader>
      <CardContent>
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-muted-foreground">
              {columns.map((c, i) => (
                <th key={i} className="text-left py-1 font-medium">{c}</th>
              ))}
              {editing && <th className="w-8" />}
            </tr>
          </thead>
          <tbody>
            {visibleRows.map((row, ri) => (
              <tr key={ri} className="border-b last:border-0">
                {row.values.map((v, ci) => (
                  <td key={ci} className="py-1">
                    {editing ? (
                      <Input
                        value={v}
                        onChange={(e) => updateCell(ri, ci, e.target.value)}
                        className={`h-7 text-xs ${mono.includes(ci) ? "font-mono" : ""}`}
                      />
                    ) : (
                      <span className={mono.includes(ci) ? "font-mono" : "text-muted-foreground"}>
                        {v || "—"}
                      </span>
                    )}
                  </td>
                ))}
                {editing && (
                  <td className="py-1 text-right">
                    <Button type="button" variant="ghost" size="icon" className="h-6 w-6"
                      onClick={() => removeRow(ri)}>
                      <X className="h-3 w-3" />
                    </Button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
        {editing && (
          <Button type="button" variant="outline" size="sm" className="mt-2" onClick={addRow}>
            <Plus className="mr-1 h-3 w-3" /> Add
          </Button>
        )}
        {!editing && visibleRows.length === 0 && (
          <p className="text-sm text-muted-foreground">None.</p>
        )}
      </CardContent>
    </Card>
  );
}

/* ── IP-specific editable table (with checkboxes) ─────── */

function IpArrayCard({
  rows,
  setRows,
  editing,
}: {
  rows: ERow[];
  setRows: (r: ERow[]) => void;
  editing: boolean;
}) {
  const visible = rows.filter((r) => !r._deleted);
  const show = editing || visible.length > 0;
  if (!show) return null;

  const update = (idx: number, col: number, val: string) => {
    const next = [...rows];
    const ri = rows.indexOf(visible[idx]);
    next[ri] = { ...next[ri], values: [...next[ri].values] };
    next[ri].values[col] = val;
    setRows(next);
  };
  const remove = (idx: number) => {
    const next = [...rows];
    const ri = rows.indexOf(visible[idx]);
    next[ri] = { ...next[ri], _deleted: true };
    setRows(next);
  };
  const add = () => setRows([...rows, { _dbId: 0, _deleted: false, values: ["", "t", "t"] }]);

  return (
    <Card>
      <CardHeader><CardTitle className="text-base">IP Addresses</CardTitle></CardHeader>
      <CardContent>
        <table className="w-full text-sm table-fixed">
          <thead>
            <tr className="border-b text-muted-foreground">
              <th className="text-left py-1 font-medium">IP</th>
              <th className="text-left py-1 font-medium w-18">Reverse</th>
              <th className="text-left py-1 font-medium w-18">Forward</th>
              {editing && <th className="w-8" />}
            </tr>
          </thead>
          <tbody>
            {visible.map((row, i) => (
              <tr key={i} className="border-b last:border-0">
                <td className="py-1 pr-2">
                  {editing ? (
                    <Input value={row.values[0]} onChange={(e) => update(i, 0, e.target.value)}
                      className="h-7 text-xs font-mono w-full" placeholder="10.0.0.1" />
                  ) : (
                    <span className="font-mono">{row.values[0]}</span>
                  )}
                </td>
                <td className="py-1">
                  {editing ? (
                    <input type="checkbox" checked={row.values[1] === "t"}
                      onChange={(e) => update(i, 1, e.target.checked ? "t" : "f")} />
                  ) : (
                    row.values[1] === "t" ? "Yes" : "No"
                  )}
                </td>
                <td className="py-1">
                  {editing ? (
                    <input type="checkbox" checked={row.values[2] === "t"}
                      onChange={(e) => update(i, 2, e.target.checked ? "t" : "f")} />
                  ) : (
                    row.values[2] === "t" ? "Yes" : "No"
                  )}
                </td>
                {editing && (
                  <td className="py-1 text-right">
                    <Button type="button" variant="ghost" size="icon" className="h-6 w-6"
                      onClick={() => remove(i)}>
                      <X className="h-3 w-3" />
                    </Button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
        {editing && (
          <Button type="button" variant="outline" size="sm" className="mt-2" onClick={add}>
            <Plus className="mr-1 h-3 w-3" /> Add IP
          </Button>
        )}
      </CardContent>
    </Card>
  );
}

/* ── main component ───────────────────────────────────── */

export default function HostDetailPage() {
  const { hostname } = useParams<{ hostname: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { serverName, zoneName } = useServerContext();
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [editing, setEditing] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);

  // Editable array state — initialised on entering edit mode
  const [ipEdit, setIpEdit] = useState<ERow[]>([]);
  const [txtEdit, setTxtEdit] = useState<ERow[]>([]);
  const [mxEdit, setMxEdit] = useState<ERow[]>([]);
  const [nsEdit, setNsEdit] = useState<ERow[]>([]);
  const [dhcpEdit, setDhcpEdit] = useState<ERow[]>([]);
  const [srvEdit, setSrvEdit] = useState<ERow[]>([]);

  const { data: host, isLoading } = useQuery({
    queryKey: ["host", serverName, zoneName, hostname],
    queryFn: () => hostsApi.get(serverName!, zoneName!, hostname!),
    enabled: !!serverName && !!zoneName && !!hostname,
  });

  const updateMutation = useMutation({
    mutationFn: (data: Partial<Host>) => hostsApi.update(serverName!, zoneName!, hostname!, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["host", serverName, zoneName, hostname] });
      setEditing(false);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: () => hostsApi.delete(serverName!, zoneName!, hostname!),
    onSuccess: () => {
      navigate("/hosts");
    },
  });

  // Enter edit mode: snapshot array data into editable state
  const enterEdit = useCallback(() => {
    if (!host) return;
    const d = host as Record<string, unknown>;
    setIpEdit(toERows(dataRows(d.ip)));
    setTxtEdit(toERows(dataRows(d.txt_l)));
    setMxEdit(toERows(dataRows(d.mx_l)));
    setNsEdit(toERows(dataRows(d.ns_l)));
    setDhcpEdit(toERows(dataRows(d.dhcp_l)));
    setSrvEdit(toERows(dataRows(d.srv_l)));
    setEditing(true);
  }, [host]);

  if (isLoading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  if (!host) {
    return (
      <div className="py-12 text-center">
        <p className="text-muted-foreground">Host not found.</p>
        <Button className="mt-4" onClick={() => navigate("/hosts")}>
          Back to Hosts
        </Button>
      </div>
    );
  }

  const d = host as Record<string, unknown>;

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setFormError(null);
    const fd = new FormData(e.currentTarget);
    const data: Record<string, unknown> = {};
    // Scalar fields (string type)
    for (const key of [
      "ether", "huser", "dept", "location", "info", "email",
      "hinfo_hw", "hinfo_sw", "duid",
      "asset_id", "model", "serial", "misc",
    ]) {
      const v = fd.get(key) as string;
      if (v) data[key] = v;
    }
    // Scalar fields (integer type)
    for (const key of ["iaid", "expiration"] as const) {
      const v = fd.get(key) as string;
      if (v && v.trim() !== "") {
        const n = Number(v);
        if (!isNaN(n) && n > 0) data[key] = n;
      }
    }
    // TTL: empty → -1 (default), otherwise validate 600-86400
    const ttlStr = fd.get("ttl") as string;
    if (ttlStr && ttlStr.trim() !== "") {
      const ttlNum = Number(ttlStr);
      if (isNaN(ttlNum) || ttlNum < 600 || ttlNum > 86400) {
        setFormError("TTL: Value outside limits (600 .. 86400)");
        return;
      }
      data.ttl = ttlNum;
    }
    // Other numeric fields (only send if non-empty/non-zero)
    for (const key of ["router", "grp", "mx", "wks"]) {
      const v = fd.get(key) as string;
      if (v && v.trim() !== "" && Number(v) !== 0) data[key] = Number(v);
    }
    // Validate TXT records: non-delete rows must have non-empty TXT value
    const txtRowsVisible = txtEdit.filter(r => !r._deleted);
    for (const row of txtRowsVisible) {
      if (!row.values[0] || row.values[0].trim() === "") {
        setFormError("TXT: Empty field not allowed");
        return;
      }
    }
    // Array fields — convert ERows to API object format
    const visibleIp = ipEdit.filter(r => !r._deleted);
    if (visibleIp.length > 0) {
      data.ips = visibleIp.map(r => r.values[0]);
    }
    const visibleTxt = txtEdit.filter(r => !r._deleted);
    if (visibleTxt.length > 0) {
      data.txt_l = visibleTxt.map(r => ({ txt: r.values[0], comment: r.values[1] || "" }));
    }
    const visibleMx = mxEdit.filter(r => !r._deleted);
    if (visibleMx.length > 0) {
      data.mx_l = visibleMx.map(r => ({ pri: Number(r.values[0]), mx: r.values[1], comment: r.values[2] || "" }));
    }
    const visibleNs = nsEdit.filter(r => !r._deleted);
    if (visibleNs.length > 0) {
      data.ns_l = visibleNs.map(r => ({ ns: r.values[0], comment: r.values[1] || "" }));
    }
    const visibleDhcp = dhcpEdit.filter(r => !r._deleted);
    if (visibleDhcp.length > 0) {
      data.dhcp_l = visibleDhcp.map(r => ({ dhcp: r.values[0], comment: r.values[1] || "" }));
    }
    const visibleSrv = srvEdit.filter(r => !r._deleted);
    if (visibleSrv.length > 0) {
      data.srv_l = visibleSrv.map(r => ({ pri: Number(r.values[0]), weight: Number(r.values[1]), port: Number(r.values[2]), target: r.values[3], comment: r.values[4] || "" }));
    }
    updateMutation.mutate(data as Partial<Host>);
  };

  // Read-only data
  const ipRows = dataRows(d.ip);
  const ipDisplay = ipRows.map((r) => String(r[1] || r[0])).join(", ");
  const mxRows = dataRows(d.mx_l);
  const nsRows = dataRows(d.ns_l);
  const txtRows = dataRows(d.txt_l);
  const aliasRows = dataRows(d.alias_l);
  const dhcpRows = dataRows(d.dhcp_l);
  const srvRows = dataRows(d.srv_l);
  const subgroupRows = dataRows(d.subgroups);

  const created = parseDateStr(d.cdate_str);
  const modified = parseDateStr(d.mdate_str);
  const hasPending = created.pending || modified.pending;

  /* ── Editable scalar fields list ──────────────────── */

  const TEXT_FIELDS = [
    { key: "domain", label: "Hostname", mono: true },
    { key: "huser", label: "User" },
    { key: "dept", label: "Dept." },
    { key: "location", label: "Location" },
    { key: "email", label: "User Email" },
    { key: "info", label: "[Extra] Info" },
  ];

  const EQUIP_FIELDS = [
    { key: "hinfo_hw", label: "HINFO hardware" },
    { key: "hinfo_sw", label: "HINFO software" },
    { key: "ether", label: "MAC Address", mono: true },
    { key: "duid", label: "DUID", mono: true },
    { key: "iaid", label: "IAID", mono: true },
    { key: "asset_id", label: "Asset ID" },
    { key: "model", label: "Model" },
    { key: "serial", label: "Serial no." },
    { key: "misc", label: "Misc." },
  ];

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center gap-4">
        <Button variant="ghost" size="icon" onClick={() => navigate(-1)}>
          <ArrowLeft className="h-4 w-4" />
        </Button>
        <div>
          <h1 className="text-2xl font-bold tracking-tight font-mono">
            {host.domain}
          </h1>
          <div className="flex items-center gap-2 mt-1">
            <Badge variant="outline">
              {HOST_TYPES[host.type] || `Type ${host.type}`}
            </Badge>
            <span className="text-sm text-muted-foreground">ID: {host.id}</span>
            {hasPending && (
              <Badge variant="destructive" className="text-xs">PENDING</Badge>
            )}
          </div>
        </div>
        <div className="ml-auto flex gap-2">
          {!editing ? (
            <>
              <Button size="sm" onClick={enterEdit}>
                <Pencil className="mr-2 h-4 w-4" />
                Edit
              </Button>
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="outline" size="sm">
                    <MoreHorizontal className="h-4 w-4" />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end">
                  <DropdownMenuItem disabled>
                    <Copy className="mr-2 h-4 w-4" /> Copy
                  </DropdownMenuItem>
                  <DropdownMenuItem disabled>
                    <Link className="mr-2 h-4 w-4" /> Add Alias
                  </DropdownMenuItem>
                  <DropdownMenuItem disabled>
                    <Ban className="mr-2 h-4 w-4" /> Disable
                  </DropdownMenuItem>
                  <DropdownMenuItem
                    className="text-destructive"
                    onClick={() => setDeleteOpen(true)}
                  >
                    <Trash2 className="mr-2 h-4 w-4" /> Delete
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </>
          ) : (
            <Button variant="outline" size="sm" onClick={() => setEditing(false)}>
              <X className="mr-2 h-4 w-4" />
              Cancel
            </Button>
          )}
        </div>
      </div>

      <form onSubmit={handleSubmit}>
        <div className="grid gap-6 md:grid-cols-2">
          {/* ── Left column: Host info + User info ──────── */}
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Host</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              {editing ? (
                <>
                  <div className="space-y-2">
                    <Label htmlFor="domain">Hostname</Label>
                    <Input id="domain" name="domain" defaultValue={host.domain} className="font-mono" />
                  </div>
                  <div className="grid grid-cols-2 gap-3">
                    <div className="space-y-1">
                      <Label htmlFor="type" className="text-xs">Type</Label>
                      <Select name="type" defaultValue={String(host.type)}>
                        <SelectTrigger className="h-8"><SelectValue /></SelectTrigger>
                        <SelectContent>
                          {Object.entries(HOST_TYPES).map(([val, label]) => (
                            <SelectItem key={val} value={val}>{label}</SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </div>
                    <div className="space-y-1">
                      <Label htmlFor="ttl" className="text-xs">TTL</Label>
                      <Input id="ttl" name="ttl" type="number" min={600} max={86400}
                        defaultValue={d.ttl && Number(d.ttl) > 0 ? String(d.ttl) : ""} placeholder="Default (600-86400)"
                        className="h-8 text-sm" />
                    </div>
                  </div>
                  <div className="space-y-1">
                    <Label htmlFor="router" className="text-xs">Router (priority, 0=off)</Label>
                    <Input id="router" name="router" type="number"
                      defaultValue={d.router ? String(d.router) : "0"}
                      className="h-8 text-sm" />
                  </div>
                    <div className="space-y-1">
                      <Label htmlFor="expiration" className="text-xs">Expiration (Unix epoch, 0=none)</Label>
                      <Input id="expiration" name="expiration" type="number"
                        defaultValue={d.expiration && Number(d.expiration) > 0 ? String(d.expiration) : ""}
                        placeholder="0" className="h-8 text-sm" />
                    </div>
                  <Separator />
                  {TEXT_FIELDS.slice(1).map((f) => (
                    <div key={f.key} className="space-y-1">
                      <Label htmlFor={f.key} className="text-xs">{f.label}</Label>
                      <Input id={f.key} name={f.key}
                        defaultValue={String((d[f.key] as string) || "")}
                        className={`h-8 text-sm ${f.mono ? "font-mono" : ""}`} />
                    </div>
                  ))}
                </>
              ) : (
                <>
                  <div className="grid grid-cols-2 gap-4">
                    <Field label="Hostname" value={host.domain} mono />
                    <Field label="FQDN" value={String(d.fqdn || "—")} mono />
                  </div>
                  <div className="grid grid-cols-2 gap-4">
                    <Field label="IP Address" value={ipDisplay} mono />
                    <Field label="Host ID" value={String(host.id)} />
                  </div>
                  <div className="grid grid-cols-2 gap-4">
                    <Field label="Type" value={HOST_TYPES[host.type] || `Type ${host.type}`} />
                    <Field label="Class" value={String(d.class || "IN")} />
                  </div>
                  <div className="grid grid-cols-2 gap-4">
                    <Field label="TTL" value={d.ttl ? String(d.ttl) : "Default"} />
                    <Field label="Router (priority)" value={d.router ? `Yes (${d.router})` : "No"} />
                  </div>
                  <Separator />
                  <div className="grid grid-cols-2 gap-4">
                    <Field label="User" value={String(d.huser || "")} />
                    <Field label="Dept." value={String(d.dept || "")} />
                  </div>
                  <div className="grid grid-cols-2 gap-4">
                    <Field label="Location" value={String(d.location || "")} />
                    <Field label="User Email" value={String(d.email || "")} />
                  </div>
                  <Field label="[Extra] Info" value={String(d.info || "")} />
                </>
              )}
            </CardContent>
          </Card>

          {/* ── Right column: IP + Equipment + Groups ──── */}
          <div className="space-y-6">
            {/* IP Addresses */}
            <IpArrayCard rows={editing ? ipEdit : toERows(ipRows)} setRows={setIpEdit} editing={editing} />

            {/* Equipment Info */}
            <Card>
              <CardHeader>
                <CardTitle className="text-base">Equipment Info</CardTitle>
              </CardHeader>
              <CardContent>
                {editing ? (
                  <div className="grid grid-cols-2 gap-3">
                    {EQUIP_FIELDS.map((f) => (
                      <div key={f.key} className="space-y-1">
                        <Label htmlFor={f.key} className="text-xs">{f.label}</Label>
                        <Input id={f.key} name={f.key} type={f.key === "iaid" ? "number" : "text"}
                          defaultValue={String((d[f.key] as string) || "")}
                          className={`h-8 text-sm ${f.mono ? "font-mono" : ""}`} />
                      </div>
                    ))}
                  </div>
                ) : (
                  <>
                    <div className="grid grid-cols-2 gap-4 text-sm">
                      <Field label="HINFO hardware" value={String(d.hinfo_hw || "—")} />
                      <Field label="HINFO software" value={String(d.hinfo_sw || "—")} />
                    </div>
                    <div className="grid grid-cols-2 gap-4 text-sm mt-3">
                      <Field label="MAC Address" value={String(d.ether || "—")} mono />
                      <Field label="Card manufacturer" value={String(d.card_info || "").replace(/&nbsp;/g, "").trim() || "—"} />
                    </div>
                    <div className="grid grid-cols-2 gap-4 text-sm mt-3">
                      <Field label="DUID" value={String(d.duid || "—")} mono />
                      <Field label="IAID" value={String(d.iaid || "—")} mono />
                    </div>
                    {(d.asset_id || d.model || d.serial || d.misc) && (
                      <div className="grid grid-cols-2 gap-4 text-sm mt-3">
                        <Field label="Asset ID" value={String(d.asset_id || "")} />
                        <Field label="Model" value={String(d.model || "")} />
                        <Field label="Serial no." value={String(d.serial || "")} />
                        <Field label="Misc." value={String(d.misc || "")} />
                      </div>
                    )}
                  </>
                )}
              </CardContent>
            </Card>

            {/* Group / Template Selections */}
            <Card>
              <CardHeader>
                <CardTitle className="text-base">Group/Template Selections</CardTitle>
              </CardHeader>
              <CardContent>
                {editing ? (
                  <div className="grid grid-cols-2 gap-3">
                    <div className="space-y-1">
                      <Label htmlFor="grp" className="text-xs">Base group (ID)</Label>
                      <Input id="grp" name="grp" type="number"
                        defaultValue={Number(d.grp) > 0 ? String(d.grp) : "0"}
                        className="h-8 text-sm" />
                    </div>
                    <div className="space-y-1">
                      <Label htmlFor="mx" className="text-xs">MX template (ID)</Label>
                      <Input id="mx" name="mx" type="number"
                        defaultValue={Number(d.mx) > 0 ? String(d.mx) : "0"}
                        className="h-8 text-sm" />
                    </div>
                    <div className="space-y-1">
                      <Label htmlFor="wks" className="text-xs">WKS template (ID)</Label>
                      <Input id="wks" name="wks" type="number"
                        defaultValue={Number(d.wks) > 0 ? String(d.wks) : "0"}
                        className="h-8 text-sm" />
                    </div>
                  </div>
                ) : (
                  <div className="grid grid-cols-2 gap-4 text-sm">
                    <Field label="Base group" value={
                      Number(d.grp) > 0
                        ? (d.grp_rec && typeof d.grp_rec === "object" && "name" in (d.grp_rec as Record<string, unknown>)
                            ? `${(d.grp_rec as Record<string, string>).name} (#${d.grp})`
                            : String(d.grp))
                        : "<Not selected>"
                    } />
                    <Field label="SubGroups" value={subgroupRows.length > 0 ? subgroupRows.map((r) => String(r[1] || r[0])).join(", ") : "<None>"} />
                    <Field label="MX template" value={
                      Number(d.mx) > 0
                        ? (d.mx_rec && typeof d.mx_rec === "object" && "name" in (d.mx_rec as Record<string, unknown>)
                            ? `${(d.mx_rec as Record<string, string>).name} (#${d.mx})`
                            : String(d.mx))
                        : "<Not selected>"
                    } />
                    <Field label="WKS template" value={
                      Number(d.wks) > 0
                        ? (d.wks_rec && typeof d.wks_rec === "object" && "name" in (d.wks_rec as Record<string, unknown>)
                            ? `${(d.wks_rec as Record<string, string>).name} (#${d.wks})`
                            : String(d.wks))
                        : "<Not selected>"
                    } />
                  </div>
                )}
              </CardContent>
            </Card>
          </div>
        </div>

        <Separator className="my-6" />

        {/* ── Full-width: TXT Records ─────────────────── */}
        <EditableArrayCard
          title="TXT Records"
          columns={["TXT", "Comment"]}
          rows={editing ? txtEdit : toERows(txtRows)}
          setRows={setTxtEdit}
          editing={editing}
        />

        {/* ── Multi-value sections in grid ────────────── */}
        <div className="grid gap-6 md:grid-cols-2 mt-6">
          <EditableArrayCard
            title="MX Records"
            columns={["Priority", "MX", "Comment"]}
            rows={editing ? mxEdit : toERows(mxRows)}
            setRows={setMxEdit}
            editing={editing}
            mono={[1]}
          />
          <EditableArrayCard
            title="NS Records"
            columns={["NS", "Comment"]}
            rows={editing ? nsEdit : toERows(nsRows)}
            setRows={setNsEdit}
            editing={editing}
          />
          <EditableArrayCard
            title="DHCP Entries"
            columns={["DHCP", "Comment"]}
            rows={editing ? dhcpEdit : toERows(dhcpRows)}
            setRows={setDhcpEdit}
            editing={editing}
          />
          <EditableArrayCard
            title="SRV Records"
            columns={["Priority", "Weight", "Port", "Target", "Comment"]}
            rows={editing ? srvEdit : toERows(srvRows)}
            setRows={setSrvEdit}
            editing={editing}
            mono={[3]}
          />
        </div>

        {/* ── Aliases (read-only — managed via separate operations) */}
        {aliasRows.length > 0 && (
          <Card className="mt-6">
            <CardHeader><CardTitle className="text-base">Aliases</CardTitle></CardHeader>
            <CardContent>
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-muted-foreground">
                    <th className="text-left py-1 font-medium">Domain</th>
                    <th className="text-left py-1 font-medium">Type</th>
                  </tr>
                </thead>
                <tbody>
                  {aliasRows.map((row, i) => (
                    <tr key={i} className="border-b last:border-0">
                      <td className="py-1 font-mono">{String(row[1] || row[0])}</td>
                      <td className="py-1">{String(row[2]) === "t" ? "CNAME" : "AREC"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </CardContent>
          </Card>
        )}

        <Separator className="my-6" />

        {/* ── Record Info ─────────────────────────────── */}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Record Info</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid gap-4 sm:grid-cols-2 text-sm">
              <div>
                <div className="text-muted-foreground">Record created</div>
                <div className="font-medium">
                  {created.text}
                  {created.pending && (
                    <Badge variant="destructive" className="ml-2 text-xs">PENDING</Badge>
                  )}
                </div>
              </div>
              <div>
                <div className="text-muted-foreground">Last modified</div>
                <div className="font-medium">
                  {modified.text}
                  {modified.pending && (
                    <Badge variant="destructive" className="ml-2 text-xs">PENDING</Badge>
                  )}
                </div>
              </div>
              <div>
                <div className="text-muted-foreground">Expiration date</div>
                <div className="font-medium">
                  {d.expiration && Number(d.expiration) > 0
                    ? String(d.expiration)
                    : <span className="text-orange-500">No expiration date set</span>}
                </div>
              </div>
              <div>
                <div className="text-muted-foreground">Last lease issued by DHCP server</div>
                <div className="font-medium">
                  {String(d.dhcp_date_str || "").trim() || "—"}
                </div>
              </div>
            </div>
          </CardContent>
        </Card>

        {/* ── Save bar (edit mode only) ───────────────── */}
        {editing && (
          <div className="flex items-center justify-end gap-2 mt-6">
            {updateMutation.isSuccess && !formError && (
              <p className="text-sm text-green-600 mr-2">Saved.</p>
            )}
            {formError && (
              <p className="text-sm text-destructive mr-2">{formError}</p>
            )}
            {updateMutation.isError && (
              <p className="text-sm text-destructive mr-2">
                {updateMutation.error instanceof Error
                  ? updateMutation.error.message
                  : "Failed to save."}
              </p>
            )}
            <Button type="button" variant="outline" onClick={() => setEditing(false)}>
              Cancel
            </Button>
            <Button type="submit" disabled={updateMutation.isPending}>
              {updateMutation.isPending ? (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              ) : (
                <Save className="mr-2 h-4 w-4" />
              )}
              Save Changes
            </Button>
          </div>
        )}
      </form>

      {/* Delete dialog */}
      <Dialog open={deleteOpen} onOpenChange={setDeleteOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete Host</DialogTitle>
            <DialogDescription>
              Delete <strong>{host.domain}</strong>? This cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteOpen(false)}>Cancel</Button>
            <Button
              variant="destructive"
              onClick={() => deleteMutation.mutate()}
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
