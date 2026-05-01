import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import type { ColumnDef } from "@tanstack/react-table";
import { zonesApi } from "@/api";
import type { Zone } from "@/lib/types";
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Plus, Pencil, Trash2, ArrowRight, Loader2, AlertCircle } from "lucide-react";
import { useState } from "react";
import { FormHint } from "@/components/FormHint";

const ZONE_TYPES: Record<string, { label: string; variant: "default" | "secondary" | "outline" }> = {
  M: { label: "Master", variant: "default" },
  S: { label: "Slave", variant: "secondary" },
  H: { label: "Hint", variant: "outline" },
  F: { label: "Forward", variant: "outline" },
};

export default function ZonesPage() {
  const { isSuperuser } = useAuth();
  const { serverName, setZone } = useServerContext();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const [editOpen, setEditOpen] = useState(false);
  const [editData, setEditData] = useState<Partial<Zone> | null>(null);
  const [deleteName, setDeleteName] = useState<string | null>(null);

  const { data: zones, isLoading } = useQuery({
    queryKey: ["zones", serverName],
    queryFn: () => zonesApi.list(serverName!),
    enabled: !!serverName,
  });

  const createMutation = useMutation({
    mutationFn: (data: { name: string; type?: string }) => zonesApi.create(serverName!, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["zones", serverName] });
      setEditOpen(false);
      setEditData(null);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (zoneName: string) => zonesApi.delete(serverName!, zoneName),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["zones", serverName] });
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

  const columns: ColumnDef<Zone>[] = [
    { accessorKey: "id", header: "ID", size: 60 },
    { accessorKey: "name", header: "Name" },
    {
      accessorKey: "type",
      header: "Type",
      cell: ({ getValue }) => {
        const type = getValue() as string;
        const zt = ZONE_TYPES[type] || { label: type, variant: "outline" as const };
        return <Badge variant={zt.variant}>{zt.label}</Badge>;
      },
    },
    {
      accessorKey: "reverse",
      header: "Reverse",
      cell: ({ getValue }) => (getValue() ? "Yes" : "No"),
    },
    {
      id: "actions",
      header: "",
      cell: ({ row }) => (
        <div className="flex items-center gap-1 justify-end">
          <Button
            variant="ghost"
            size="icon"
            className="h-8 w-8"
            onClick={(e) => {
              e.stopPropagation();
              setZone(row.original.id, row.original.name);
              navigate("/hosts");
            }}
            title="Browse hosts"
          >
            <ArrowRight className="h-4 w-4" />
          </Button>
          {isSuperuser && (
            <>
              <Button
                variant="ghost"
                size="icon"
                className="h-8 w-8"
                onClick={(e) => {
                  e.stopPropagation();
                  navigate(`/zones/${encodeURIComponent(row.original.name)}`);
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
                  setDeleteName(row.original.name);
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
          <h1 className="text-2xl font-bold tracking-tight">Zones</h1>
          <p className="text-muted-foreground">
            {serverName} — {zones?.length ?? 0} zone{zones?.length !== 1 ? "s" : ""}
          </p>
        </div>
        {isSuperuser && (
          <Button
            onClick={() => {
              setEditData({});
              setEditOpen(true);
            }}
          >
            <Plus className="mr-2 h-4 w-4" />
            Add Zone
          </Button>
        )}
      </div>

      <DataTable
        columns={columns}
        data={zones || []}
        isLoading={isLoading}
        emptyMessage="No zones found."
        onRowClick={(zone) => {
          setZone(zone.id, zone.name);
          navigate(`/zones/${encodeURIComponent(zone.name)}`);
        }}
      />

      {/* Create dialog */}
      {editOpen && !editData?.id && (
        <Dialog open={editOpen} onOpenChange={() => { setEditOpen(false); setEditData(null); }}>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>New Zone</DialogTitle>
              <DialogDescription>Create a new DNS zone on {serverName}.</DialogDescription>
            </DialogHeader>
            <form
              onSubmit={(e) => {
                e.preventDefault();
                const fd = new FormData(e.currentTarget);
                createMutation.mutate({
                  name: fd.get("name") as string,
                  type: fd.get("type") as string,
                });
              }}
              className="space-y-4"
            >
              <div className="space-y-2">
                <Label htmlFor="name" className="inline-flex items-center">
                  Zone Name
                  <FormHint text="For forward zones use the domain name (e.g. example.com). For reverse zones use the CIDR notation of the corresponding network." />
                </Label>
                <Input id="name" name="name" placeholder="example.com" required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="type" className="inline-flex items-center">
                  Type
                  <FormHint text="Master: authoritative zone. Slave: secondary copy from master. Forward: forward queries to another server. Hint: root server hints." />
                </Label>
                <Select name="type" defaultValue="M">
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="M">Master</SelectItem>
                    <SelectItem value="S">Slave</SelectItem>
                    <SelectItem value="H">Hint</SelectItem>
                    <SelectItem value="F">Forward</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="reverse" className="inline-flex items-center">
                  Reverse
                  <FormHint text="Set to Yes for reverse (PTR) zones. The CIDR of a forward zone can be used as the name of the corresponding reverse zone. Mask length must be a multiple of 8 (IPv4) or 4 (IPv6)." />
                </Label>
                <Select name="reverse" defaultValue="false">
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="false">No</SelectItem>
                    <SelectItem value="true">Yes</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              <DialogFooter>
                <Button type="button" variant="outline" onClick={() => { setEditOpen(false); setEditData(null); }}>
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
      <Dialog open={deleteName !== null} onOpenChange={() => setDeleteName(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete Zone</DialogTitle>
            <DialogDescription>
              Are you sure? This will delete all hosts in this zone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteName(null)}>Cancel</Button>
            <Button
              variant="destructive"
              onClick={() => deleteName && deleteMutation.mutate(deleteName)}
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
