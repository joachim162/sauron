import { useParams, useNavigate } from "react-router-dom";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { zonesApi } from "@/api";
import type { Zone } from "@/lib/types";
import { useAuth } from "@/hooks/use-auth";
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
import { ArrowLeft, Save, Loader2, Trash2, ExternalLink, Pencil, X, MoreHorizontal, Plus } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  DialogDescription,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useState, useCallback } from "react";
import { FormHint } from "@/components/FormHint";

const ZONE_TYPES: Record<string, string> = {
  M: "Master",
  S: "Slave",
  H: "Hint",
  F: "Forward",
};

const CHECK_NAMES: Record<string, string> = {
  D: "Default",
  W: "Warn",
  F: "Fail",
  I: "Ignore",
};

const NOTIFY_VALUES: Record<string, string> = {
  D: "Default",
  Y: "Yes",
  N: "No",
};

/* ── helpers ──────────────────────────────────────────── */

/** Extract data rows from BackEnd arrays (skip header row). */
function dataRows(arr: unknown): unknown[][] {
  if (!Array.isArray(arr) || arr.length <= 1) return [];
  return arr.slice(1) as unknown[][];
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
  _dbId: number;
  _deleted: boolean;
  values: string[];
};

function toERows(raw: unknown[][]): ERow[] {
  // r = [dbId, val1, val2, ..., modeFlag]
  // slice(1, -1) strips both the DB id (first) and the mode flag (last)
  // that get_array_field always appends.
  return raw.map((r) => ({
    _dbId: Number(r[0]) || 0,
    _deleted: false,
    values: r.slice(1, -1).map((v) => String(v ?? "")),
  }));
}

function buildArray(headers: string[], rows: ERow[]): unknown[][] {
  const out: unknown[][] = [headers];
  for (const r of rows) {
    if (r._deleted && r._dbId > 0) {
      out.push([r._dbId, ...r.values, -1]);
    } else if (r._deleted) {
      continue;
    } else if (r._dbId === 0) {
      out.push([0, ...r.values, 2]);
    } else {
      out.push([r._dbId, ...r.values, 1]);
    }
  }
  return out;
}

/* ── generic editable array card ─────────────────────── */

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
  const visible = rows.filter((r) => !r._deleted);
  if (!editing && visible.length === 0) return null;

  const updateCell = (idx: number, col: number, val: string) => {
    const next = [...rows];
    const ri = rows.indexOf(visible[idx]);
    next[ri] = { ...next[ri], values: [...next[ri].values] };
    next[ri].values[col] = val;
    setRows(next);
  };
  const removeRow = (idx: number) => {
    const next = [...rows];
    const ri = rows.indexOf(visible[idx]);
    next[ri] = { ...next[ri], _deleted: true };
    setRows(next);
  };
  const addRow = () => setRows([...rows, { _dbId: 0, _deleted: false, values: columns.map(() => "") }]);

  return (
    <Card>
      <CardHeader><CardTitle className="text-base">{title}</CardTitle></CardHeader>
      <CardContent>
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-muted-foreground">
              {columns.map((c, i) => <th key={i} className="text-left py-1 font-medium">{c}</th>)}
              {editing && <th className="w-8" />}
            </tr>
          </thead>
          <tbody>
            {visible.map((row, ri) => (
              <tr key={ri} className="border-b last:border-0">
                {row.values.map((v, ci) => (
                  <td key={ci} className="py-1">
                    {editing ? (
                      <Input value={v} onChange={(e) => updateCell(ri, ci, e.target.value)}
                        className={`h-7 text-xs ${mono.includes(ci) ? "font-mono" : ""}`} />
                    ) : (
                      <span className={mono.includes(ci) ? "font-mono" : "text-muted-foreground"}>{v || "—"}</span>
                    )}
                  </td>
                ))}
                {editing && (
                  <td className="py-1 text-right">
                    <Button type="button" variant="ghost" size="icon" className="h-6 w-6"
                      onClick={() => removeRow(ri)}><X className="h-3 w-3" /></Button>
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
        {!editing && visible.length === 0 && (
          <p className="text-sm text-muted-foreground">None configured.</p>
        )}
      </CardContent>
    </Card>
  );
}

/* ── IP table with checkboxes ────────────────────────── */

function IpArrayCard({
  rows, setRows, editing,
}: {
  rows: ERow[];
  setRows: (r: ERow[]) => void;
  editing: boolean;
}) {
  const visible = rows.filter((r) => !r._deleted);
  if (!editing && visible.length === 0) return null;

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
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-muted-foreground">
              <th className="text-left py-1 font-medium">IP</th>
              <th className="text-left py-1 font-medium w-20">Reverse</th>
              <th className="text-left py-1 font-medium w-20">Forward</th>
              {editing && <th className="w-8" />}
            </tr>
          </thead>
          <tbody>
            {visible.map((row, i) => (
              <tr key={i} className="border-b last:border-0">
                <td className="py-1">
                  {editing ? (
                    <Input value={row.values[0]} onChange={(e) => update(i, 0, e.target.value)}
                      className="h-7 text-xs font-mono" placeholder="10.0.0.1" />
                  ) : <span className="font-mono">{row.values[0]}</span>}
                </td>
                <td className="py-1">
                  {editing ? (
                    <input type="checkbox" checked={row.values[1] === "t"}
                      onChange={(e) => update(i, 1, e.target.checked ? "t" : "f")} />
                  ) : row.values[1] === "t" ? "Yes" : "No"}
                </td>
                <td className="py-1">
                  {editing ? (
                    <input type="checkbox" checked={row.values[2] === "t"}
                      onChange={(e) => update(i, 2, e.target.checked ? "t" : "f")} />
                  ) : row.values[2] === "t" ? "Yes" : "No"}
                </td>
                {editing && (
                  <td className="py-1 text-right">
                    <Button type="button" variant="ghost" size="icon" className="h-6 w-6"
                      onClick={() => remove(i)}><X className="h-3 w-3" /></Button>
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
        {!editing && visible.length === 0 && (
          <p className="text-sm text-muted-foreground">No IP addresses configured.</p>
        )}
      </CardContent>
    </Card>
  );
}

/* ── main component ───────────────────────────────────── */

export default function ZoneDetailPage() {
  const { name: zoneNameParam } = useParams<{ name: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { isSuperuser } = useAuth();
  const { serverName, setZone } = useServerContext();
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [editing, setEditing] = useState(false);

  // Editable array state
  const [ipEdit, setIpEdit] = useState<ERow[]>([]);
  const [nsEdit, setNsEdit] = useState<ERow[]>([]);
  const [mxEdit, setMxEdit] = useState<ERow[]>([]);
  const [txtEdit, setTxtEdit] = useState<ERow[]>([]);
  const [alsoNotifyEdit, setAlsoNotifyEdit] = useState<ERow[]>([]);
  const [dhcpEdit, setDhcpEdit] = useState<ERow[]>([]);
  const [zentriesTaEdit, setZentriesTaEdit] = useState<ERow[]>([]);

  const { data: zone, isLoading } = useQuery({
    queryKey: ["zone", serverName, zoneNameParam],
    queryFn: () => zonesApi.get(serverName!, zoneNameParam!),
    enabled: !!serverName && !!zoneNameParam,
  });

  const updateMutation = useMutation({
    mutationFn: (data: Partial<Zone>) => zonesApi.update(serverName!, zoneNameParam!, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["zone", serverName, zoneNameParam] });
      setEditing(false);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: () => zonesApi.delete(serverName!, zoneNameParam!),
    onSuccess: () => {
      navigate("/zones");
    },
  });

  // Enter edit mode: snapshot array data into editable state
  const enterEdit = useCallback(() => {
    if (!zone) return;
    const d = zone as Record<string, unknown>;
    setIpEdit(toERows(dataRows(d.ip)));
    setNsEdit(toERows(dataRows(d.ns)));
    setMxEdit(toERows(dataRows(d.mx)));
    setTxtEdit(toERows(dataRows(d.txt)));
    setAlsoNotifyEdit(toERows(dataRows(d.also_notify)));
    setDhcpEdit(toERows(dataRows(d.dhcp)));
    setZentriesTaEdit(toERows(dataRows(d.zentries_ta)));
    setEditing(true);
  }, [zone]);

  if (isLoading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  if (!zone) {
    return (
      <div className="py-12 text-center">
        <p className="text-muted-foreground">Zone not found.</p>
        <Button className="mt-4" onClick={() => navigate("/zones")}>
          Back to Zones
        </Button>
      </div>
    );
  }

  const zoneData = zone as Record<string, unknown>;
  const isMaster = zoneData.type === "M";

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    const data: Record<string, unknown> = {};

    // String fields
    for (const key of ["name", "comment", "hostmaster", "expiration"]) {
      const v = fd.get(key) as string;
      if (v !== null && v !== undefined) data[key] = v;
    }
    // Enum fields
    for (const key of ["chknames", "nnotify", "class"]) {
      const v = fd.get(key) as string;
      if (v) data[key] = v;
    }
    // Integer fields (SOA) — empty string means use server default (send 0)
    for (const key of ["refresh", "retry", "expire", "minimum", "ttl"]) {
      const v = fd.get(key) as string;
      data[key] = v ? Number(v) : 0;
    }
    // Boolean/flag fields
    const txtAuto = fd.get("txt_auto_generation") as string;
    if (txtAuto !== null) data.txt_auto_generation = Number(txtAuto);
    const dummy = fd.get("dummy") as string;
    if (dummy !== null) data.dummy = dummy === "true";

    // Array fields
    data.ip = buildArray(["IP", "reverse", "forward"], ipEdit);
    data.ns = buildArray(["NS", "Comments"], nsEdit);
    data.mx = buildArray(["Priority", "MX", "Comments"], mxEdit);
    data.txt = buildArray(["TXT", "Comments"], txtEdit);
    data.also_notify = buildArray(["IP", "Comments"], alsoNotifyEdit);
    data.dhcp = buildArray(["DHCP", "Comments"], dhcpEdit);
    data.zentries_ta = buildArray(["Zone Entry"], zentriesTaEdit);

    updateMutation.mutate(data as Partial<Zone>);
  };

  // Read-only data for view mode
  const nsRows = dataRows(zoneData.ns);
  const mxRows = dataRows(zoneData.mx);
  const txtRows = dataRows(zoneData.txt);
  const ipRows = dataRows(zoneData.ip);
  const alsoNotifyRows = dataRows(zoneData.also_notify);
  const dhcpRows = dataRows(zoneData.dhcp);
  const zentriesTaRows = dataRows(zoneData.zentries_ta);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center gap-4">
        <Button variant="ghost" size="icon" onClick={() => navigate("/zones")}>
          <ArrowLeft className="h-4 w-4" />
        </Button>
        <div>
          <h1 className="text-2xl font-bold tracking-tight font-mono">
            {zone.name}
          </h1>
          <div className="flex items-center gap-2 mt-1">
            <Badge>{ZONE_TYPES[zone.type] || zone.type}</Badge>
            {Boolean(zoneData.reverse) && <Badge variant="secondary">Reverse</Badge>}
            <span className="text-sm text-muted-foreground">ID: {zone.id}</span>
          </div>
        </div>
        <div className="ml-auto flex gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={() => {
              setZone(zone.id, zone.name);
              navigate("/hosts");
            }}
          >
            <ExternalLink className="mr-2 h-4 w-4" />
            Browse Hosts
          </Button>
          {isSuperuser && !editing && (
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
                  <DropdownMenuItem
                    className="text-destructive"
                    onClick={() => setDeleteOpen(true)}
                  >
                    <Trash2 className="mr-2 h-4 w-4" /> Delete
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </>
          )}
          {editing && (
            <Button variant="outline" size="sm" onClick={() => setEditing(false)}>
              <X className="mr-2 h-4 w-4" />
              Cancel
            </Button>
          )}
        </div>
      </div>

      <form onSubmit={handleSubmit}>
        <div className="grid gap-6 md:grid-cols-2">
          {/* Zone Configuration */}
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Zone Configuration</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              {editing ? (
                <>
                  <div className="space-y-2">
                    <Label htmlFor="name">Zone Name</Label>
                    <Input id="name" name="name" defaultValue={zone.name} className="font-mono" />
                  </div>
                  <div className="grid grid-cols-2 gap-4">
                    <Field label="Type" value={ZONE_TYPES[zone.type] || zone.type} />
                    <Field label="Reverse" value={zoneData.reverse ? "Yes" : "No"} />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="comment">Comments</Label>
                    <Input id="comment" name="comment" defaultValue={String(zoneData.comment || "")} />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="class">Class</Label>
                    <Select name="class" defaultValue={String(zoneData.class || "in")}>
                      <SelectTrigger><SelectValue /></SelectTrigger>
                      <SelectContent>
                        <SelectItem value="in">IN (internet)</SelectItem>
                        <SelectItem value="hs">HS</SelectItem>
                        <SelectItem value="hesiod">Hesiod</SelectItem>
                        <SelectItem value="chaos">Chaos</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="txt_auto_generation">Info TXT auto generation</Label>
                    <Select name="txt_auto_generation" defaultValue={String(zoneData.txt_auto_generation || 0)}>
                      <SelectTrigger><SelectValue /></SelectTrigger>
                      <SelectContent>
                        <SelectItem value="0">No</SelectItem>
                        <SelectItem value="1">Yes</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="dummy">"Dummy" zone</Label>
                    <Select name="dummy" defaultValue={String(zoneData.dummy ?? false)}>
                      <SelectTrigger><SelectValue /></SelectTrigger>
                      <SelectContent>
                        <SelectItem value="false">No</SelectItem>
                        <SelectItem value="true">Yes</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>

                  {isMaster && (
                    <div className="space-y-2">
                      <Label htmlFor="hostmaster" className="inline-flex items-center">
                        Hostmaster
                        <FormHint text="Email of the zone admin as FQDN (e.g. hostmaster.example.com.). Leave empty to use default from server." />
                      </Label>
                      <Input id="hostmaster" name="hostmaster"
                        defaultValue={String(zoneData.hostmaster || "")}
                        placeholder="(empty = default)" />
                    </div>
                  )}

                  <div className="space-y-2">
                    <Label htmlFor="chknames">Check-names</Label>
                    <Select name="chknames" defaultValue={String(zoneData.chknames || "D")}>
                      <SelectTrigger><SelectValue /></SelectTrigger>
                      <SelectContent>
                        {Object.entries(CHECK_NAMES).map(([k, v]) => (
                          <SelectItem key={k} value={k}>{v}</SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>
                  {isMaster && (
                    <div className="space-y-2">
                      <Label htmlFor="nnotify">Notify</Label>
                      <Select name="nnotify" defaultValue={String(zoneData.nnotify || "D")}>
                        <SelectTrigger><SelectValue /></SelectTrigger>
                        <SelectContent>
                          {Object.entries(NOTIFY_VALUES).map(([k, v]) => (
                            <SelectItem key={k} value={k}>{v}</SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </div>
                  )}
                </>
              ) : (
                <>
                  <div className="grid grid-cols-2 gap-4">
                    <Field label="Zone Name" value={zone.name} mono />
                    <Field label="Type" value={ZONE_TYPES[zone.type] || zone.type} />
                    <Field label="Reverse" value={zoneData.reverse ? "Yes" : "No"} />
                    <Field label="Class" value={String(zoneData.class || "IN").toUpperCase()} />
                  </div>
                  <Separator />
                  <Field label="Comments" value={String(zoneData.comment || "")} />
                  {isMaster && (
                    <>
                      <Field label="Hostmaster" value={String(zoneData.hostmaster || "Default (from server)")} mono />
                      <div className="grid grid-cols-2 gap-4">
                        <Field label="Info TXT auto generation" value={Number(zoneData.txt_auto_generation) ? "Yes" : "No"} />
                        <Field label="Dummy zone" value={zoneData.dummy ? "Yes" : "No"} />
                      </div>
                      <div className="grid grid-cols-2 gap-4">
                        <Field label="Check-names" value={CHECK_NAMES[String(zoneData.chknames || "D")] || "Default"} />
                        <Field label="Notify" value={NOTIFY_VALUES[String(zoneData.nnotify || "D")] || "Default"} />
                      </div>
                    </>
                  )}
                </>
              )}
            </CardContent>
          </Card>

          {/* SOA Parameters */}
          <Card>
            <CardHeader>
              <CardTitle className="text-base">SOA Parameters</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              <Field label="Serial" value={String(zoneData.serial || "—")} mono />

              {editing && isMaster ? (
                <div className="grid grid-cols-2 gap-3">
                  {[
                    { key: "refresh", label: "Refresh" },
                    { key: "retry", label: "Retry" },
                    { key: "expire", label: "Expire" },
                    { key: "minimum", label: "Minimum (neg. cache TTL)" },
                    { key: "ttl", label: "Default TTL" },
                  ].map((f) => (
                    <div key={f.key} className="space-y-1">
                      <Label htmlFor={f.key} className="text-xs">{f.label}</Label>
                      <Input id={f.key} name={f.key} type="number"
                        defaultValue={zoneData[f.key] ? String(zoneData[f.key]) : ""}
                        placeholder="(empty = default)" className="h-8 text-sm" />
                    </div>
                  ))}
                </div>
              ) : (
                <div className="grid grid-cols-2 gap-4">
                  <Field label="Refresh" value={zoneData.refresh ? String(zoneData.refresh) : "Default (from server)"} />
                  <Field label="Retry" value={zoneData.retry ? String(zoneData.retry) : "Default (from server)"} />
                  <Field label="Expire" value={zoneData.expire ? String(zoneData.expire) : "Default (from server)"} />
                  <Field label="Minimum (neg. cache TTL)" value={zoneData.minimum ? String(zoneData.minimum) : "Default (from server)"} />
                  <Field label="Default TTL" value={zoneData.ttl ? String(zoneData.ttl) : "Default (from server)"} />
                </div>
              )}
            </CardContent>
          </Card>
        </div>

        <Separator className="my-6" />

        {/* Multi-value sections */}
        <div className="grid gap-6 md:grid-cols-2">
          <IpArrayCard rows={editing ? ipEdit : toERows(ipRows)} setRows={setIpEdit} editing={editing} />

          <EditableArrayCard title="Name Servers (NS)" columns={["NS", "Comment"]}
            rows={editing ? nsEdit : toERows(nsRows)} setRows={setNsEdit} editing={editing} />

          <EditableArrayCard title="Mail Exchanges (MX)" columns={["Priority", "MX", "Comment"]}
            rows={editing ? mxEdit : toERows(mxRows)} setRows={setMxEdit} editing={editing} mono={[1]} />

          <EditableArrayCard title="Info (TXT)" columns={["TXT", "Comment"]}
            rows={editing ? txtEdit : toERows(txtRows)} setRows={setTxtEdit} editing={editing} />

          <EditableArrayCard title="Custom Zone File Entries" columns={["Zone Entry"]}
            rows={editing ? zentriesTaEdit : toERows(zentriesTaRows)} setRows={setZentriesTaEdit} editing={editing} />

          <EditableArrayCard title="Stealth Servers to Notify" columns={["IP", "Comment"]}
            rows={editing ? alsoNotifyEdit : toERows(alsoNotifyRows)} setRows={setAlsoNotifyEdit} editing={editing} />
        </div>

        {/* DHCP section (master only) */}
        {(isMaster && (editing || dhcpRows.length > 0)) && (
          <>
            <Separator className="my-6" />
            <EditableArrayCard title="Zone Specific DHCP Entries" columns={["DHCP", "Comment"]}
              rows={editing ? dhcpEdit : toERows(dhcpRows)} setRows={setDhcpEdit} editing={editing} />
          </>
        )}

        <Separator className="my-6" />

        {/* Record Info + Expiration */}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Record Info</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid gap-4 sm:grid-cols-2 md:grid-cols-4 text-sm">
              <Field label="Zone ID" value={String(zone.id)} />
              <Field label="Record Created" value={String(zoneData.cdate_str || "—").replace(/<[^>]*>/g, "").trim()} />
              <Field label="Last Modified" value={String(zoneData.mdate_str || "—").replace(/<[^>]*>/g, "").trim() || "—"} />
              {editing ? (
                <div>
                  <Label htmlFor="expiration" className="text-xs text-muted-foreground">Expiration Date</Label>
                  <Input id="expiration" name="expiration"
                    defaultValue={zoneData.expiration ? String(zoneData.expiration) : ""}
                    placeholder="DD-MM-YYYY or +30d"
                    className="h-8 text-sm mt-1" />
                </div>
              ) : (
                <div>
                  <div className="text-muted-foreground text-xs">Expiration Date</div>
                  <div className="font-medium text-sm">
                    {zoneData.expiration
                      ? String(zoneData.expiration)
                      : <span className="text-orange-500">No expiration date set</span>}
                  </div>
                </div>
              )}
            </div>
          </CardContent>
        </Card>

        {/* Save bar — only in edit mode */}
        {editing && (
          <div className="flex items-center justify-end gap-2 mt-6">
            {updateMutation.isSuccess && (
              <p className="text-sm text-green-600 mr-2">Saved.</p>
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
            <DialogTitle>Delete Zone</DialogTitle>
            <DialogDescription>
              Delete <strong>{zone.name}</strong>? This will remove all hosts in this zone.
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
