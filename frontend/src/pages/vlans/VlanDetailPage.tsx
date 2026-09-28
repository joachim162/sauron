import { useParams, useNavigate } from "react-router-dom";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { vlansApi } from "@/api";
import type { Vlan, DhcpEntry, UpdateVlan } from "@/lib/types";
import { useServerContext } from "@/hooks/use-server-context";
import { useAuth } from "@/hooks/use-auth";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Skeleton } from "@/components/ui/skeleton";
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

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-muted-foreground text-xs">{label}</div>
      <div className="font-medium text-sm">{value || "—"}</div>
    </div>
  );
}

function EntryEditor({
  rows,
  onChange,
}: {
  rows: DhcpEntry[];
  onChange: (rows: DhcpEntry[]) => void;
}) {
  return (
    <div className="space-y-2">
      {rows.map((row, idx) => (
        <div key={idx} className="flex items-center gap-2">
          <Input
            value={row.dhcp ?? ""}
            placeholder="option ..."
            onChange={(e) => {
              const next = [...rows];
              next[idx] = { ...next[idx], dhcp: e.target.value };
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
        onClick={() => onChange([...rows, { dhcp: "" }])}
      >
        <Plus className="mr-2 h-4 w-4" />
        Add entry
      </Button>
    </div>
  );
}

function EntryList({ rows }: { rows: DhcpEntry[] }) {
  if (!rows.length) return <p className="text-sm text-muted-foreground">None</p>;
  return (
    <div className="divide-y rounded-md border">
      {rows.map((row, idx) => (
        <div key={idx} className="flex items-center justify-between px-3 py-2 text-sm">
          <span className="font-mono">{row.dhcp}</span>
          <span className="text-muted-foreground">{row.comment || ""}</span>
        </div>
      ))}
    </div>
  );
}

export default function VlanDetailPage() {
  const { name } = useParams<{ name: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { serverName } = useServerContext();
  const { isSuperuser } = useAuth();

  const decodedName = name ? decodeURIComponent(name) : "";

  const [editing, setEditing] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [form, setForm] = useState<Partial<Vlan>>({});
  const [dhcp, setDhcp] = useState<DhcpEntry[]>([]);
  const [dhcp6, setDhcp6] = useState<DhcpEntry[]>([]);

  const { data: vlan, isLoading } = useQuery({
    queryKey: ["vlans", serverName, decodedName],
    queryFn: () => vlansApi.get(serverName!, decodedName),
    enabled: !!serverName && !!decodedName,
  });

  useEffect(() => {
    if (vlan) {
      setForm({ ...vlan });
      setDhcp(vlan.dhcp_l ? [...vlan.dhcp_l] : []);
      setDhcp6(vlan.dhcp_l6 ? [...vlan.dhcp_l6] : []);
    }
  }, [vlan]);

  const updateMutation = useMutation({
    mutationFn: (data: UpdateVlan) => vlansApi.update(serverName!, decodedName, data),
    onSuccess: (updated) => {
      queryClient.invalidateQueries({ queryKey: ["vlans", serverName] });
      setEditing(false);
      if (updated.name !== decodedName) {
        navigate(`/vlans/${encodeURIComponent(updated.name)}`, { replace: true });
      } else {
        queryClient.invalidateQueries({ queryKey: ["vlans", serverName, decodedName] });
      }
    },
  });

  const deleteMutation = useMutation({
    mutationFn: () => vlansApi.delete(serverName!, decodedName),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["vlans", serverName] });
      navigate("/vlans");
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

  if (!vlan) {
    return (
      <div className="flex flex-col items-center justify-center py-12">
        <h2 className="text-xl font-semibold">VLAN not found</h2>
        <Button className="mt-4" onClick={() => navigate("/vlans")}>Back to VLANs</Button>
      </div>
    );
  }

  function handleSave() {
    updateMutation.mutate({
      name: form.name,
      vlanno: form.vlanno ?? null,
      description: form.description ?? null,
      comment: form.comment ?? null,
      dhcp_l: dhcp.filter((r) => r.dhcp.trim() !== ""),
      dhcp_l6: dhcp6.filter((r) => r.dhcp.trim() !== ""),
    });
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Button variant="outline" size="icon" onClick={() => navigate("/vlans")}>
            <ArrowLeft className="h-4 w-4" />
          </Button>
          <div>
            <h1 className="text-2xl font-bold tracking-tight">{vlan.name}</h1>
            <p className="text-muted-foreground text-sm">
              {vlan.vlanno != null ? `VLAN ${vlan.vlanno}` : "No VLAN number"}
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
              <Button size="sm" variant="destructive" onClick={() => setDeleteOpen(true)}>
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
                  setForm({ ...vlan });
                  setDhcp([...vlan.dhcp_l]);
                  setDhcp6([...vlan.dhcp_l6]);
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
            : "Failed to update VLAN."}
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
                <Label htmlFor="vlanno">VLAN No.</Label>
                <Input
                  id="vlanno"
                  type="number"
                  min={0}
                  value={form.vlanno ?? ""}
                  onChange={(e) =>
                    setForm((p) => ({
                      ...p,
                      vlanno: e.target.value === "" ? null : Number(e.target.value),
                    }))
                  }
                />
              </div>
              <div className="space-y-2 col-span-2">
                <Label htmlFor="description">Description</Label>
                <Input
                  id="description"
                  value={form.description ?? ""}
                  onChange={(e) => setForm((p) => ({ ...p, description: e.target.value }))}
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
              <Field label="ID" value={String(vlan.id)} />
              <Field label="VLAN No." value={vlan.vlanno != null ? String(vlan.vlanno) : ""} />
              <Field label="Description" value={vlan.description ?? ""} />
              <Field label="Comment" value={vlan.comment ?? ""} />
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
            <EntryEditor rows={dhcp} onChange={setDhcp} />
          ) : (
            <EntryList rows={vlan.dhcp_l} />
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">DHCPv6 entries</CardTitle>
        </CardHeader>
        <CardContent>
          {editing ? (
            <EntryEditor rows={dhcp6} onChange={setDhcp6} />
          ) : (
            <EntryList rows={vlan.dhcp_l6} />
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
              value={vlan.cdate ? `${new Date(vlan.cdate * 1000).toLocaleString()} by ${vlan.cuser ?? ""}` : ""}
            />
            <Field
              label="Last modified"
              value={vlan.mdate ? `${new Date(vlan.mdate * 1000).toLocaleString()} by ${vlan.muser ?? ""}` : ""}
            />
          </div>
        </CardContent>
      </Card>

      <Dialog open={deleteOpen} onOpenChange={setDeleteOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete VLAN</DialogTitle>
            <DialogDescription>
              Are you sure you want to delete <strong>{vlan.name}</strong>? Networks and VMPS
              domains referencing it are detached. This cannot be undone.
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
                : "Failed to delete VLAN."}
            </p>
          )}
        </DialogContent>
      </Dialog>
    </div>
  );
}
