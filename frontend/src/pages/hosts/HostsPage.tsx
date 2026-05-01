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
  const [deleteHostname, setDeleteHostname] = useState<string | null>(null);

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
    mutationFn: (data: { hostname: string; type: number; ips?: string[] }) =>
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
                createMutation.mutate({
                  hostname: fd.get("domain") as string,
                  type: Number(fd.get("type")),
                  ips: (fd.get("ip") as string) ? [(fd.get("ip") as string)] : undefined,
                });
              }}
              className="space-y-4"
            >
              <div className="space-y-2">
                <Label htmlFor="domain">Domain</Label>
                <Input id="domain" name="domain" placeholder="server1" required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="type">Type</Label>
                <Select name="type" defaultValue="1">
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
              <div className="space-y-2">
                <Label htmlFor="ip">IP Address</Label>
                <Input id="ip" name="ip" placeholder="192.168.1.10" />
              </div>
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
