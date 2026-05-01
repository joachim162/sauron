import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import type { ColumnDef } from "@tanstack/react-table";
import { serversApi } from "@/api";
import type { Server } from "@/lib/types";
import { useAuth } from "@/hooks/use-auth";
import { useServerContext } from "@/hooks/use-server-context";
import { DataTable } from "@/components/DataTable";
import { Button } from "@/components/ui/button";
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
import { Plus, Pencil, Trash2, ArrowRight, Loader2 } from "lucide-react";
import { useState } from "react";
import { FormHint } from "@/components/FormHint";

const columns: ColumnDef<Server>[] = [
  { accessorKey: "id", header: "ID", size: 60 },
  { accessorKey: "name", header: "Name" },
  { accessorKey: "hostname", header: "Hostname" },
  { accessorKey: "hostaddr", header: "IP Address" },
  { accessorKey: "comment", header: "Comment" },
  {
    id: "actions",
    header: "",
    cell: () => null, // filled dynamically
  },
];

export default function ServersPage() {
  const { isSuperuser } = useAuth();
  const { setServer } = useServerContext();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const [editOpen, setEditOpen] = useState(false);
  const [editData, setEditData] = useState<Partial<Server> | null>(null);
  const [deleteName, setDeleteName] = useState<string | null>(null);

  const { data: servers, isLoading } = useQuery({
    queryKey: ["servers"],
    queryFn: serversApi.list,
  });

  const createMutation = useMutation({
    mutationFn: (data: Partial<Server>) => serversApi.create(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["servers"] });
      setEditOpen(false);
      setEditData(null);
    },
  });

  const updateMutation = useMutation({
    mutationFn: ({ name, data }: { name: string; data: Partial<Server> }) =>
      serversApi.update(name, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["servers"] });
      setEditOpen(false);
      setEditData(null);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (name: string) => serversApi.delete(name),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["servers"] });
      setDeleteName(null);
    },
  });

  const tableColumns: ColumnDef<Server>[] = columns.map((col) => {
    if (col.id === "actions") {
      return {
        ...col,
        cell: ({ row }) => (
          <div className="flex items-center gap-1 justify-end">
            <Button
              variant="ghost"
              size="icon"
              className="h-8 w-8"
              onClick={(e) => {
                e.stopPropagation();
                setServer(row.original.id, row.original.name);
                navigate("/zones");
              }}
              title="Select server"
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
                    setEditData(row.original);
                    setEditOpen(true);
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
      };
    }
    return col;
  });

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Servers</h1>
          <p className="text-muted-foreground">
            {servers?.length ?? 0} server{servers?.length !== 1 ? "s" : ""}
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
            Add Server
          </Button>
        )}
      </div>

      <DataTable
        columns={tableColumns}
        data={servers || []}
        isLoading={isLoading}
        emptyMessage="No servers found."
        onRowClick={(server) => {
          setServer(server.id, server.name);
          navigate("/zones");
        }}
      />

      {/* Edit/Create dialog */}
      <ServerDialog
        open={editOpen}
        data={editData}
        servers={servers || []}
        onClose={() => {
          setEditOpen(false);
          setEditData(null);
        }}
        onSave={(data) => {
          if (editData?.id) {
            updateMutation.mutate({ name: editData.name!, data });
          } else {
            createMutation.mutate(data);
          }
        }}
        isLoading={createMutation.isPending || updateMutation.isPending}
      />

      {/* Delete dialog */}
      <Dialog open={deleteName !== null} onOpenChange={() => setDeleteName(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete Server</DialogTitle>
            <DialogDescription>
              Are you sure you want to delete this server? This action cannot be
              undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteName(null)}>
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={() => deleteName && deleteMutation.mutate(deleteName)}
              disabled={deleteMutation.isPending}
            >
              {deleteMutation.isPending && (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              )}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function ServerDialog({
  open,
  data,
  servers,
  onClose,
  onSave,
  isLoading,
}: {
  open: boolean;
  data: Partial<Server> | null;
  servers: Server[];
  onClose: () => void;
  onSave: (data: Partial<Server>) => void;
  isLoading: boolean;
}) {
  const isEdit = !!data?.id;

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    const masterserver = fd.get("masterserver") as string;
    onSave({
      ...(isEdit ? { id: data!.id } : {}),
      name: fd.get("name") as string,
      hostname: fd.get("hostname") as string,
      hostaddr: fd.get("hostaddr") as string,
      hostmaster: fd.get("hostmaster") as string,
      directory: fd.get("directory") as string,
      masterserver: masterserver ? Number(masterserver) : -1,
      comment: fd.get("comment") as string,
    });
  };

  // Other servers available as master (exclude self)
  const masterOptions = servers.filter((s) => s.id !== data?.id);

  return (
    <Dialog open={open} onOpenChange={onClose}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "Edit Server" : "New Server"}</DialogTitle>
          <DialogDescription>
            {isEdit ? "Update server configuration." : "Create a new DNS/DHCP server."}
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="name" className="inline-flex items-center">
              Name
              <FormHint text="Short identifier for this server (e.g. ns1, dns-prod). Used internally to reference this server." />
            </Label>
            <Input
              id="name"
              name="name"
              defaultValue={data?.name || ""}
              required
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="hostname" className="inline-flex items-center">
              Hostname
              <FormHint text="Fully qualified domain name of the server (e.g. ns1.example.com.). Used in SOA records as the primary nameserver." />
            </Label>
            <Input
              id="hostname"
              name="hostname"
              defaultValue={data?.hostname || ""}
              placeholder="ns1.example.com."
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="hostaddr" className="inline-flex items-center">
              IP Address
              <FormHint text="IP address of this DNS/DHCP server. Used for generating configurations and health checks." />
            </Label>
            <Input
              id="hostaddr"
              name="hostaddr"
              defaultValue={(data?.hostaddr as string) || ""}
              placeholder="192.168.1.1"
              required
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="hostmaster" className="inline-flex items-center">
              Hostmaster
              <FormHint text="Email of the zone administrator as FQDN (e.g. hostmaster.example.com.). Used in SOA records. Leave empty to use server default." />
            </Label>
            <Input
              id="hostmaster"
              name="hostmaster"
              defaultValue={data?.hostmaster || ""}
              placeholder="hostmaster.example.com."
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="directory" className="inline-flex items-center">
              Configuration Directory
              <FormHint text="Directory where BIND configuration and zone files will be generated (e.g. /etc/named or /var/named)." />
            </Label>
            <Input
              id="directory"
              name="directory"
              defaultValue={data?.directory || ""}
              placeholder="/etc/named"
              required
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="masterserver" className="inline-flex items-center">
              Slave For
              <FormHint text="If this server is a slave (secondary), select the master server it replicates from." />
            </Label>
            <select
              id="masterserver"
              name="masterserver"
              defaultValue={String((data as Record<string, unknown>)?.masterserver ?? "")}
              className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-xs transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            >
              <option value="">— None —</option>
              {masterOptions.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-2">
            <Label htmlFor="comment" className="inline-flex items-center">
              Comment
              <FormHint text="Optional description or notes about this server." />
            </Label>
            <Input
              id="comment"
              name="comment"
              defaultValue={data?.comment || ""}
            />
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={isLoading}>
              {isLoading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              {isEdit ? "Save" : "Create"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
