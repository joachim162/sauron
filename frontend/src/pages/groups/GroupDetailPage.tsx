import { useParams, useNavigate } from "react-router-dom";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { groupsApi } from "@/api";
import type { Group, GroupType, DhcpEntry, PrinterEntry, UpdateGroup } from "@/lib/types";
import { GROUP_TYPES } from "@/lib/types";
import { useServerContext } from "@/hooks/use-server-context";
import { useAuth } from "@/hooks/use-auth";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  DialogDescription,
} from "@/components/ui/dialog";
import { ArrowLeft, Save, Loader2, Trash2, Pencil, X, Plus } from "lucide-react";
import { useState, useEffect } from "react";
import { ApiRequestError } from "@/lib/api-client";

const TYPE_OPTIONS = Object.keys(GROUP_TYPES) as GroupType[];

function typeVariant(type: GroupType) {
  if (type === "custom_dhcp_class") return "outline" as const;
  if (type === "dhcp_class") return "secondary" as const;
  return "default" as const;
}

function Field({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div>
      <div className="text-muted-foreground text-xs">{label}</div>
      <div className={`font-medium text-sm ${mono ? "font-mono" : ""}`}>{value || "—"}</div>
    </div>
  );
}

// Generic two-column entry editor ({dhcp,comment} or {printer,comment}).
function EntryEditor<T extends { comment?: string }>({
  label,
  valueKey,
  rows,
  onChange,
  placeholder,
}: {
  label: string;
  valueKey: keyof T & string;
  rows: T[];
  onChange: (rows: T[]) => void;
  placeholder?: string;
}) {
  return (
    <div className="space-y-2">
      {rows.map((row, idx) => (
        <div key={idx} className="flex items-center gap-2">
          <Input
            value={(row[valueKey] as unknown as string) ?? ""}
            placeholder={placeholder}
            onChange={(e) => {
              const next = [...rows];
              next[idx] = { ...next[idx], [valueKey]: e.target.value };
              onChange(next);
            }}
            className="flex-1"
          />
          <Input
            value={row.comment ?? ""}
            placeholder="comment"
            onChange={(e) => {
              const next = [...rows];
              next[idx] = { ...next[idx], comment: e.target.value };
              onChange(next);
            }}
            className="w-48"
          />
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="h-8 w-8 text-destructive"
            onClick={() => onChange(rows.filter((_, i) => i !== idx))}
          >
            <X className="h-4 w-4" />
          </Button>
        </div>
      ))}
      <Button
        type="button"
        variant="outline"
        size="sm"
        onClick={() => onChange([...rows, { [valueKey]: "" } as unknown as T])}
      >
        <Plus className="mr-2 h-4 w-4" />
        Add {label}
      </Button>
    </div>
  );
}

function EntryList<T extends { comment?: string }>({
  rows,
  valueKey,
}: {
  rows: T[];
  valueKey: keyof T & string;
}) {
  if (!rows.length) return <p className="text-sm text-muted-foreground">None</p>;
  return (
    <div className="divide-y rounded-md border">
      {rows.map((row, idx) => (
        <div key={idx} className="flex items-center justify-between px-3 py-2 text-sm">
          <span className="font-mono">{(row[valueKey] as unknown as string) ?? ""}</span>
          <span className="text-muted-foreground">{row.comment || ""}</span>
        </div>
      ))}
    </div>
  );
}

export default function GroupDetailPage() {
  const { name } = useParams<{ name: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { serverName } = useServerContext();
  const { isSuperuser } = useAuth();

  const decodedName = name ? decodeURIComponent(name) : "";

  const [editing, setEditing] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [form, setForm] = useState<Partial<Group>>({});
  const [dhcp, setDhcp] = useState<DhcpEntry[]>([]);
  const [dhcp6, setDhcp6] = useState<DhcpEntry[]>([]);
  const [printer, setPrinter] = useState<PrinterEntry[]>([]);

  const { data: group, isLoading } = useQuery({
    queryKey: ["groups", serverName, decodedName],
    queryFn: () => groupsApi.get(serverName!, decodedName),
    enabled: !!serverName && !!decodedName,
  });

  useEffect(() => {
    if (group) {
      setForm({ ...group });
      setDhcp(group.dhcp_l ? [...group.dhcp_l] : []);
      setDhcp6(group.dhcp_l6 ? [...group.dhcp_l6] : []);
      setPrinter(group.printer_l ? [...group.printer_l] : []);
    }
  }, [group]);

  const updateMutation = useMutation({
    mutationFn: (data: UpdateGroup) => groupsApi.update(serverName!, decodedName, data),
    onSuccess: (updated) => {
      queryClient.invalidateQueries({ queryKey: ["groups", serverName] });
      setEditing(false);
      if (updated.name !== decodedName) {
        navigate(`/groups/${encodeURIComponent(updated.name)}`, { replace: true });
      } else {
        queryClient.invalidateQueries({ queryKey: ["groups", serverName, decodedName] });
      }
    },
  });

  const deleteMutation = useMutation({
    mutationFn: () => groupsApi.delete(serverName!, decodedName),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["groups", serverName] });
      navigate("/groups");
    },
  });

  if (!serverName) {
    return (
      <div className="flex flex-col items-center justify-center py-12">
        <h2 className="text-xl font-semibold">No Server Selected</h2>
        <Button className="mt-4" onClick={() => navigate("/")}>Go to Dashboard</Button>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  if (!group) {
    return (
      <div className="flex flex-col items-center justify-center py-12">
        <h2 className="text-xl font-semibold">Group not found</h2>
        <Button className="mt-4" onClick={() => navigate("/groups")}>Back to Groups</Button>
      </div>
    );
  }

  const type = (form.type ?? group.type) as GroupType;
  const isNormal = type === "normal";

  function handleSave() {
    const data: UpdateGroup = {
      name: form.name,
      type,
      alevel: form.alevel,
      vmps: form.vmps ?? null,
      comment: form.comment,
      dhcp_l: dhcp.filter((r) => r.dhcp.trim() !== ""),
      dhcp_l6: dhcp6.filter((r) => r.dhcp.trim() !== ""),
    };
    if (isNormal) {
      data.printer_l = printer.filter((r) => r.printer.trim() !== "");
    }
    updateMutation.mutate(data);
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Button variant="outline" size="icon" onClick={() => navigate("/groups")}>
            <ArrowLeft className="h-4 w-4" />
          </Button>
          <div>
            <h1 className="text-2xl font-bold tracking-tight">{group.name}</h1>
            <p className="text-muted-foreground text-sm">
              <Badge variant={typeVariant(group.type)} className="text-xs">
                {GROUP_TYPES[group.type] ?? group.type}
              </Badge>
            </p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {isSuperuser && !editing && (
            <>
              <Button size="sm" onClick={() => setEditing(true)}>
                <Pencil className="mr-2 h-4 w-4" />
                Edit
              </Button>
              <Button
                size="sm"
                variant="destructive"
                onClick={() => setDeleteOpen(true)}
              >
                <Trash2 className="mr-2 h-4 w-4" />
                Delete
              </Button>
            </>
          )}
          {editing && (
            <>
              <Button
                variant="outline"
                size="sm"
                onClick={() => {
                  setEditing(false);
                  setForm({ ...group });
                  setDhcp([...group.dhcp_l]);
                  setDhcp6([...group.dhcp_l6]);
                  setPrinter([...group.printer_l]);
                }}
              >
                <X className="mr-2 h-4 w-4" />
                Cancel
              </Button>
              <Button size="sm" onClick={handleSave} disabled={updateMutation.isPending}>
                {updateMutation.isPending ? (
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                ) : (
                  <Save className="mr-2 h-4 w-4" />
                )}
                Save
              </Button>
            </>
          )}
        </div>
      </div>

      {updateMutation.isError && (
        <p className="text-sm text-destructive">
          {updateMutation.error instanceof ApiRequestError
            ? updateMutation.error.data.message || updateMutation.error.message
            : "Failed to update group."}
        </p>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Details</CardTitle>
        </CardHeader>
        <CardContent>
          {editing ? (
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-2">
                <Label htmlFor="name">Name</Label>
                <Input
                  id="name"
                  value={form.name ?? ""}
                  onChange={(e) => setForm((p) => ({ ...p, name: e.target.value }))}
                />
              </div>
              <div className="space-y-2">
                <Label>Type</Label>
                <Select
                  value={type}
                  onValueChange={(v) => setForm((p) => ({ ...p, type: v as GroupType }))}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {TYPE_OPTIONS.map((t) => (
                      <SelectItem key={t} value={t}>
                        {GROUP_TYPES[t]}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="alevel">Authorization level</Label>
                <Input
                  id="alevel"
                  type="number"
                  min={0}
                  value={form.alevel ?? 0}
                  onChange={(e) => setForm((p) => ({ ...p, alevel: Number(e.target.value) }))}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="vmps">VMPS domain id</Label>
                <Input
                  id="vmps"
                  type="number"
                  value={form.vmps ?? ""}
                  onChange={(e) =>
                    setForm((p) => ({
                      ...p,
                      vmps: e.target.value === "" ? null : Number(e.target.value),
                    }))
                  }
                />
              </div>
              <div className="space-y-2 col-span-2">
                <Label htmlFor="comment">Comment</Label>
                <Textarea
                  id="comment"
                  value={form.comment ?? ""}
                  onChange={(e) => setForm((p) => ({ ...p, comment: e.target.value }))}
                />
              </div>
            </div>
          ) : (
            <div className="grid grid-cols-2 gap-4">
              <Field label="ID" value={String(group.id)} />
              <Field label="Authorization level" value={String(group.alevel)} />
              <Field label="VMPS domain" value={group.vmps_name ?? "—"} />
              <Field label="Comment" value={group.comment} />
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">DHCP entries</CardTitle>
        </CardHeader>
        <CardContent>
          {editing ? (
            <EntryEditor label="entry" valueKey="dhcp" rows={dhcp} onChange={setDhcp} placeholder="option ..." />
          ) : (
            <EntryList rows={group.dhcp_l} valueKey="dhcp" />
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">DHCPv6 entries</CardTitle>
        </CardHeader>
        <CardContent>
          {editing ? (
            <EntryEditor label="entry" valueKey="dhcp" rows={dhcp6} onChange={setDhcp6} placeholder="option ..." />
          ) : (
            <EntryList rows={group.dhcp_l6} valueKey="dhcp" />
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">
            PRINTER entries {!isNormal && <span className="text-muted-foreground text-xs">(normal groups only)</span>}
          </CardTitle>
        </CardHeader>
        <CardContent>
          {editing ? (
            isNormal ? (
              <EntryEditor label="printer" valueKey="printer" rows={printer} onChange={setPrinter} placeholder="printer name" />
            ) : (
              <p className="text-sm text-muted-foreground">
                PRINTER entries are only available for normal groups.
              </p>
            )
          ) : (
            <EntryList rows={group.printer_l} valueKey="printer" />
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Record info</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-2 gap-4">
            <Field
              label="Created"
              value={group.cdate ? `${new Date(group.cdate * 1000).toLocaleString()} by ${group.cuser ?? ""}` : "—"}
            />
            <Field
              label="Last modified"
              value={group.mdate ? `${new Date(group.mdate * 1000).toLocaleString()} by ${group.muser ?? ""}` : "—"}
            />
          </div>
        </CardContent>
      </Card>

      <Dialog open={deleteOpen} onOpenChange={setDeleteOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete Host Group</DialogTitle>
            <DialogDescription>
              Are you sure you want to delete <strong>{group.name}</strong>? Member hosts are
              detached. This cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={() => deleteMutation.mutate()}
              disabled={deleteMutation.isPending}
            >
              {deleteMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Delete
            </Button>
          </DialogFooter>
          {deleteMutation.isError && (
            <p className="text-sm text-destructive">
              {deleteMutation.error instanceof ApiRequestError
                ? deleteMutation.error.data.message || deleteMutation.error.message
                : "Failed to delete group."}
            </p>
          )}
        </DialogContent>
      </Dialog>
    </div>
  );
}
