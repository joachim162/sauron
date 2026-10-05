import { useParams, useNavigate } from "react-router-dom";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { aclsApi, keysApi } from "@/api";
import type { Acl, AmlElement, UpdateAcl } from "@/lib/types";
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { ArrowLeft, Save, Loader2, Trash2, Pencil, X } from "lucide-react";
import { useState, useEffect, useMemo } from "react";
import { ApiRequestError } from "@/lib/api-client";
import { AclMembersEditor, AclMembersList } from "./AclMembersEditor";

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-muted-foreground text-xs">{label}</div>
      <div className="font-medium text-sm">{value || "—"}</div>
    </div>
  );
}

export default function AclDetailPage() {
  const { name } = useParams<{ name: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { serverName } = useServerContext();
  const { isSuperuser } = useAuth();

  const decodedName = name ? decodeURIComponent(name) : "";

  const [editing, setEditing] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [reassignTo, setReassignTo] = useState<string>("detach");
  const [form, setForm] = useState<Partial<Acl>>({});
  const [members, setMembers] = useState<AmlElement[]>([]);

  const { data: acl, isLoading } = useQuery({
    queryKey: ["acls", serverName, decodedName],
    queryFn: () => aclsApi.get(serverName!, decodedName),
    enabled: !!serverName && !!decodedName,
  });

  const { data: allAcls = [] } = useQuery({
    queryKey: ["acls", serverName, "all"],
    queryFn: () => aclsApi.all(serverName!),
    enabled: !!serverName,
  });

  const { data: allKeys = [] } = useQuery({
    queryKey: ["keys", serverName, "all"],
    queryFn: () => keysApi.all(serverName!),
    enabled: !!serverName,
  });

  useEffect(() => {
    if (acl) {
      setForm({ ...acl });
      setMembers(acl.acl ? [...acl.acl] : []);
    }
  }, [acl]);

  const aclNameById = useMemo(
    () => new Map(allAcls.map((a) => [a.id, a.name])),
    [allAcls]
  );
  const keyNameById = useMemo(
    () => new Map(allKeys.map((k) => [k.id, k.name])),
    [allKeys]
  );

  const updateMutation = useMutation({
    mutationFn: (data: UpdateAcl) => aclsApi.update(serverName!, decodedName, data),
    onSuccess: (updated) => {
      queryClient.invalidateQueries({ queryKey: ["acls", serverName] });
      setEditing(false);
      if (updated.name !== decodedName) {
        navigate(`/acls/${encodeURIComponent(updated.name)}`, { replace: true });
      } else {
        queryClient.invalidateQueries({ queryKey: ["acls", serverName, decodedName] });
      }
    },
  });

  const deleteMutation = useMutation({
    mutationFn: () =>
      aclsApi.delete(
        serverName!,
        decodedName,
        reassignTo !== "detach" ? Number(reassignTo) : undefined
      ),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["acls", serverName] });
      navigate("/acls");
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

  if (!acl) {
    return (
      <div className="flex flex-col items-center justify-center py-12">
        <h2 className="text-xl font-semibold">ACL not found</h2>
        <Button className="mt-4" onClick={() => navigate("/acls")}>Back to ACLs</Button>
      </div>
    );
  }

  function handleSave() {
    updateMutation.mutate({
      name: form.name,
      comment: form.comment ?? null,
      acl: members.map((m) => ({ ...m, comment: m.comment || null })),
    });
  }

  const reassignTargets = allAcls.filter((a) => a.id !== acl.id);

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Button variant="outline" size="icon" onClick={() => navigate("/acls")}>
            <ArrowLeft className="h-4 w-4" />
          </Button>
          <div>
            <h1 className="text-2xl font-bold tracking-tight">{acl.name}</h1>
            <p className="text-muted-foreground text-sm">
              {acl.ref_count} rule{acl.ref_count !== 1 ? "s" : ""} use{acl.ref_count === 1 ? "s" : ""} this ACL
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
                  setForm({ ...acl });
                  setMembers([...acl.acl]);
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
            : "Failed to update ACL."}
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
              <Field label="ID" value={String(acl.id)} />
              <Field label="Comment" value={acl.comment ?? ""} />
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">ACL Rules</CardTitle>
        </CardHeader>
        <CardContent>
          {editing ? (
            <AclMembersEditor
              rows={members}
              onChange={setMembers}
              acls={allAcls}
              keys={allKeys}
              selfId={acl.id}
            />
          ) : (
            <AclMembersList
              rows={acl.acl}
              aclNameById={aclNameById}
              keyNameById={keyNameById}
            />
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
              value={acl.cdate ? `${new Date(acl.cdate * 1000).toLocaleString()} by ${acl.cuser ?? ""}` : ""}
            />
            <Field
              label="Last modified"
              value={acl.mdate ? `${new Date(acl.mdate * 1000).toLocaleString()} by ${acl.muser ?? ""}` : ""}
            />
          </div>
        </CardContent>
      </Card>

      <Dialog open={deleteOpen} onOpenChange={(o) => { setDeleteOpen(o); if (!o) setReassignTo("detach"); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete ACL</DialogTitle>
            <DialogDescription>
              Are you sure you want to delete <strong>{acl.name}</strong>? This cannot be undone.
            </DialogDescription>
          </DialogHeader>

          {acl.ref_count > 0 && (
            <div className="space-y-3">
              <p className="text-sm">
                <strong>{acl.ref_count}</strong> rule{acl.ref_count !== 1 ? "s" : ""} use
                {acl.ref_count === 1 ? "s" : ""} this ACL. Choose a replacement ACL for them,
                or detach them.
              </p>
              <div className="space-y-2">
                <Label htmlFor="reassign">Change references to point to</Label>
                <Select value={reassignTo} onValueChange={setReassignTo}>
                  <SelectTrigger id="reassign">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="detach">Detach (no ACL)</SelectItem>
                    {reassignTargets.map((a) => (
                      <SelectItem key={a.id} value={String(a.id)}>
                        {a.name}
                        {a.builtin ? " (built-in)" : ""}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>
          )}

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
                : "Failed to delete ACL."}
            </p>
          )}
        </DialogContent>
      </Dialog>
    </div>
  );
}
