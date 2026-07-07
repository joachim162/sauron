import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import type { ColumnDef } from "@tanstack/react-table";
import { netsApi } from "@/api";
import type { Net } from "@/lib/types";
import { useAuth } from "@/hooks/use-auth";
import { useServerContext } from "@/hooks/use-server-context";
import { DataTable } from "@/components/DataTable";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  DialogDescription,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Plus, Pencil, Trash2, Loader2, AlertCircle } from "lucide-react";
import { useState } from "react";

function dhcpLabel(dhcp: boolean | null | undefined) {
  if (dhcp === null || dhcp === undefined) return "N/A";
  return dhcp ? "Enabled" : "Disabled";
}

export default function NetsPage() {
  const { isSuperuser } = useAuth();
  const { serverName } = useServerContext();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const [createOpen, setCreateOpen] = useState(false);
  const [deleteName, setDeleteName] = useState<string | null>(null);

  const { data: nets, isLoading } = useQuery({
    queryKey: ["nets", serverName],
    queryFn: () => netsApi.list(serverName!),
    enabled: !!serverName,
  });

  const createMutation = useMutation({
    mutationFn: (data: { netname: string; name: string; net: string; comment?: string }) =>
      netsApi.create(serverName!, { ...data, subnet: false }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["nets", serverName] });
      setCreateOpen(false);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (netname: string) => netsApi.delete(serverName!, netname),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["nets", serverName] });
      setDeleteName(null);
    },
  });

  if (!serverName) {
    return (
      <div className="flex flex-col items-center justify-center py-12 text-center">
        <AlertCircle className="h-12 w-12 text-muted-foreground mb-4" />
        <h2 className="text-xl font-semibold">No Server Selected</h2>
        <p className="text-muted-foreground mt-1 mb-4">
          Select a server from the dashboard first.
        </p>
        <Button onClick={() => navigate("/")}>Go to Dashboard</Button>
      </div>
    );
  }

  const columns: ColumnDef<Net>[] = [
    { accessorKey: "id", header: "ID", size: 60 },
    { accessorKey: "netname", header: "Netname" },
    { accessorKey: "name", header: "Description" },
    { accessorKey: "net", header: "CIDR" },
    {
      accessorKey: "subnet",
      header: "Type",
      cell: ({ getValue }) => (getValue() ? "Subnet" : "Net"),
    },
    {
      accessorKey: "dummy",
      header: "Virtual",
      cell: ({ getValue }) => (getValue() ? "Yes" : "No"),
    },
    {
      accessorKey: "dhcp",
      header: "DHCP",
      cell: ({ getValue }) => {
        const value = getValue() as boolean | null | undefined;
        return (
          <Badge variant={value === true ? "default" : value === false ? "secondary" : "outline"}>
            {dhcpLabel(value)}
          </Badge>
        );
      },
    },
    {
      accessorKey: "vlan_name",
      header: "VLAN",
      cell: ({ row }) => row.original.vlan_name || String(row.original.vlan ?? "") || "—",
    },
    { accessorKey: "alevel", header: "Level" },
    {
      id: "actions",
      header: "",
      cell: ({ row }) => (
        <div className="flex items-center gap-1 justify-end">
          {isSuperuser && (
            <>
              <Button
                variant="ghost"
                size="icon"
                className="h-8 w-8"
                onClick={(e) => {
                  e.stopPropagation();
                  navigate(`/nets/${encodeURIComponent(row.original.netname)}`);
                }}
                title="Edit"
              >
                <Pencil className="h-4 w-4" />
              </Button>
              <Button
                variant="ghost"
                size="icon"
                className="h-8 w-8 text-destructive"
                onClick={(e) => {
                  e.stopPropagation();
                  setDeleteName(row.original.netname);
                }}
                title="Delete"
              >
                <Trash2 className="h-4 w-4" />
              </Button>
            </>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Networks</h1>
          <p className="text-muted-foreground">
            {serverName} — {nets?.length ?? 0} network{nets?.length !== 1 ? "s" : ""}
          </p>
        </div>
        {isSuperuser && (
          <Button onClick={() => setCreateOpen(true)}>
            <Plus className="mr-2 h-4 w-4" />
            Add Network
          </Button>
        )}
      </div>

      <DataTable
        columns={columns}
        data={nets || []}
        isLoading={isLoading}
        emptyMessage="No networks found."
        onRowClick={(net) => navigate(`/nets/${encodeURIComponent(net.netname)}`)}
      />

      {/* Create dialog */}
      {createOpen && (
        <Dialog open={createOpen} onOpenChange={() => setCreateOpen(false)}>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>New Network</DialogTitle>
              <DialogDescription>Create a new network on {serverName}.</DialogDescription>
            </DialogHeader>
            <form
              onSubmit={(e) => {
                e.preventDefault();
                const fd = new FormData(e.currentTarget);
                createMutation.mutate({
                  netname: fd.get("netname") as string,
                  name: fd.get("name") as string,
                  net: fd.get("net") as string,
                  comment: (fd.get("comment") as string) || undefined,
                });
              }}
            >
              <div className="grid gap-4 py-4">
                <div className="grid gap-2">
                  <Label htmlFor="netname">Netname</Label>
                  <Input id="netname" name="netname" required />
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="name">Description</Label>
                  <Input id="name" name="name" required />
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="type">Type</Label>
                  <Input id="type" name="type" value="Net" disabled />
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="net">Net (CIDR)</Label>
                  <Input id="net" name="net" placeholder="192.168.1.0/24" required />
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="comment">Comment</Label>
                  <Textarea id="comment" name="comment" />
                </div>
              </div>
              <DialogFooter>
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
      {deleteName && (
        <Dialog open={!!deleteName} onOpenChange={() => setDeleteName(null)}>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Delete Network</DialogTitle>
              <DialogDescription>
                Are you sure you want to delete <strong>{deleteName}</strong>? This cannot be undone.
              </DialogDescription>
            </DialogHeader>
            <DialogFooter>
              <Button variant="outline" onClick={() => setDeleteName(null)}>
                Cancel
              </Button>
              <Button
                variant="destructive"
                onClick={() => deleteMutation.mutate(deleteName)}
                disabled={deleteMutation.isPending}
              >
                {deleteMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                Delete
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}
    </div>
  );
}
