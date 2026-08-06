import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useSearchParams } from "react-router-dom";
import type { ColumnDef, PaginationState } from "@tanstack/react-table";
import { netsApi } from "@/api";
import type { Net, NewNet } from "@/lib/types";
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Plus, Trash2, Loader2, AlertCircle } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { ApiRequestError } from "@/lib/api-client";

function dhcpLabel(dhcp: boolean | null | undefined) {
  if (dhcp === null || dhcp === undefined) return "N/A";
  return dhcp ? "Enabled" : "Disabled";
}

const PAGE_SIZE_OPTIONS = [10, 25, 50, 100];

// List sub-categories, mirroring the legacy CGI list modes (filtered
// server-side; see the list query parameter): "" = top-level nets,
// sub = + subnets, all = everything,
// free = everything + unallocated blocks (id=-1 pseudo records)
const LIST_MODES: Record<string, { title: string; api: string }> = {
  "": { title: "Networks", api: "top" },
  sub: { title: "Networks + Subnets", api: "sub" },
  all: { title: "All Networks", api: "all" },
  free: { title: "Networks + Free Blocks", api: "free" },
};

function isUnallocated(net: Net) {
  return net.id === -1;
}

function unallocatedLabel(cidr: string) {
  const parts = cidr.split("/");
  if (parts.length < 2) return "";
  const [ip, maskStr] = parts;
  const bits = ip.includes(":") ? 128 : 32;
  const hostBits = bits - parseInt(maskStr, 10);
  const count = 2n ** BigInt(hostBits);
  const countLabel = count <= 65536n ? String(count) : `2^${hostBits}`;
  return `${countLabel} unallocated address${count === 1n ? "" : "es"}`;
}

export default function NetsPage() {
  const { isSuperuser } = useAuth();
  const { serverName } = useServerContext();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [searchParams, setSearchParams] = useSearchParams();

  const listParam = searchParams.get("list") ?? "";
  const listMode = LIST_MODES[listParam] ? listParam : "";

  const pagination = useMemo<PaginationState>(() => {
    const page = Math.max(1, parseInt(searchParams.get("page") || "1", 10) || 1);
    const perPageRaw = parseInt(searchParams.get("per_page") || "50", 10) || 50;
    const perPage = Math.min(100, Math.max(1, perPageRaw));
    return { pageIndex: page - 1, pageSize: perPage };
  }, [searchParams]);

  const updatePagination = (next: PaginationState) => {
    setSearchParams(
      (prev) => {
        const params = new URLSearchParams(prev);
        params.set("page", String(next.pageIndex + 1));
        params.set("per_page", String(next.pageSize));
        return params;
      },
      { replace: true }
    );
  };

  const prevListRef = useRef(listMode);
  useEffect(() => {
    if (prevListRef.current === listMode) return;
    prevListRef.current = listMode;
    setSearchParams(
      (prev) => {
        const current = prev.get("page");
        if (!current || current === "1") return prev;
        const params = new URLSearchParams(prev);
        params.set("page", "1");
        return params;
      },
      { replace: true }
    );
  }, [listMode, setSearchParams]);

  const [createOpen, setCreateOpen] = useState(false);
  const [createSubnet, setCreateSubnet] = useState(false);
  const [createDummy, setCreateDummy] = useState(false);
  const [deleteName, setDeleteName] = useState<string | null>(null);

  const { data: netsResponse, isLoading } = useQuery({
    queryKey: ["nets", serverName, listMode, pagination.pageIndex, pagination.pageSize],
    queryFn: () =>
      netsApi.list(serverName!, {
        list: LIST_MODES[listMode].api,
        page: pagination.pageIndex + 1,
        per_page: pagination.pageSize,
      }),
    enabled: !!serverName,
  });

  const nets = netsResponse?.data ?? [];
  const totalNets = netsResponse?.metadata.pagination.total ?? nets.length;
  const pageCount = netsResponse?.metadata.pagination.total_pages ?? 1;
  const pageSizeOptions = PAGE_SIZE_OPTIONS.includes(pagination.pageSize)
    ? PAGE_SIZE_OPTIONS
    : [...PAGE_SIZE_OPTIONS, pagination.pageSize].sort((a, b) => a - b);

  const createMutation = useMutation({
    mutationFn: (data: NewNet) => netsApi.create(serverName!, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["nets", serverName] });
      setCreateOpen(false);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (netname: string) => netsApi.delete(serverName!, netname),
    onSuccess: () => {
      if (nets.length === 1 && pagination.pageIndex > 0) {
        updatePagination({ ...pagination, pageIndex: pagination.pageIndex - 1 });
      }
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
    {
      accessorKey: "id",
      header: "ID",
      size: 60,
      cell: ({ row }) => (isUnallocated(row.original) ? "—" : row.original.id),
    },
    { accessorKey: "netname", header: "Netname" },
    {
      accessorKey: "name",
      header: "Description",
      cell: ({ row }) =>
        isUnallocated(row.original) ? (
          <span className="text-muted-foreground italic">
            {unallocatedLabel(row.original.net)}
          </span>
        ) : (
          row.original.name
        ),
    },
    { accessorKey: "net", header: "CIDR" },
    {
      accessorKey: "subnet",
      header: "Type",
      cell: ({ row }) => (
        <Badge variant="outline" className="text-xs">
          {isUnallocated(row.original) ? "Free" : row.original.subnet ? "Subnet" : "Net"}
        </Badge>
      ),
    },
    {
      accessorKey: "dummy",
      header: "Virtual",
      cell: ({ row }) =>
        isUnallocated(row.original) ? "—" : row.original.dummy ? "Yes" : "No",
    },
    {
      accessorKey: "dhcp",
      header: "DHCP",
      cell: ({ row }) => {
        if (isUnallocated(row.original)) return "—";
        const value = row.original.dhcp;
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
      cell: ({ row }) =>
        isUnallocated(row.original)
          ? "—"
          : row.original.vlan_name || String(row.original.vlan ?? "") || "—",
    },
    {
      accessorKey: "alevel",
      header: "Level",
      cell: ({ row }) => (isUnallocated(row.original) ? "—" : row.original.alevel),
    },
    {
      id: "actions",
      header: "",
      cell: ({ row }) =>
        isUnallocated(row.original) ? null : (
          <div className="flex items-center gap-1 justify-end">
            <Button
              variant="ghost"
              size="sm"
              onClick={(e) => {
                e.stopPropagation();
                navigate(`/nets/${encodeURIComponent(row.original.netname)}`);
              }}
            >
              Detail
            </Button>
            {isSuperuser && (
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
            )}
          </div>
        ),
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">{LIST_MODES[listMode].title}</h1>
          <p className="text-muted-foreground">
            {serverName} — {totalNets} record{totalNets !== 1 ? "s" : ""}
          </p>
        </div>
        {isSuperuser && (
          <Button
            onClick={() => {
              setCreateSubnet(false);
              setCreateDummy(false);
              setCreateOpen(true);
            }}
          >
            <Plus className="mr-2 h-4 w-4" />
            Add Network
          </Button>
        )}
      </div>

      {/* Search bar — disabled until search API is available */}
      <form onSubmit={(e) => e.preventDefault()} className="flex gap-2">
        <div className="relative flex-1">
          <Input value="" readOnly placeholder="Search coming soon..." className="pl-9 opacity-50" />
        </div>
        <Button type="submit" variant="secondary" disabled>
          Search
        </Button>
      </form>

      <div className="space-y-2">
        <div className="flex items-center justify-end gap-2">
          <span className="text-sm text-muted-foreground">Rows per page</span>
          <Select
            value={String(pagination.pageSize)}
            onValueChange={(v) => updatePagination({ pageIndex: 0, pageSize: Number(v) })}
          >
            <SelectTrigger className="w-24 h-8">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {pageSizeOptions.map((size) => (
                <SelectItem key={size} value={String(size)}>
                  {size}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <DataTable
          columns={columns}
          data={nets}
          isLoading={isLoading}
          pageCount={pageCount}
          pagination={pagination}
          onPaginationChange={updatePagination}
          emptyMessage="No networks found."
          onRowClick={(net) => {
            if (!isUnallocated(net)) navigate(`/nets/${encodeURIComponent(net.netname)}`);
          }}
        />
      </div>

      {/* Create dialog */}
      {createOpen && (
        <Dialog open={createOpen} onOpenChange={() => setCreateOpen(false)}>
          <DialogContent className="max-w-lg">
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
                  subnet: createSubnet,
                  dummy: createSubnet && createDummy,
                  comment: (fd.get("comment") as string) || undefined,
                });
              }}
              className="space-y-4"
            >
              <div className="space-y-2">
                <Label htmlFor="netname">Netname</Label>
                <Input id="netname" name="netname" required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="name">Description</Label>
                <Input id="name" name="name" required />
              </div>
              <div className="space-y-2">
                <Label>Type</Label>
                <Select
                  value={createSubnet ? "true" : "false"}
                  onValueChange={(v) => {
                    const subnet = v === "true";
                    setCreateSubnet(subnet);
                    if (!subnet) setCreateDummy(false);
                  }}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="false">Net</SelectItem>
                    <SelectItem value="true">Subnet</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              {createSubnet && (
                <div className="space-y-2">
                  <Label>Virtual subnet</Label>
                  <Select
                    value={createDummy ? "true" : "false"}
                    onValueChange={(v) => setCreateDummy(v === "true")}
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="false">No</SelectItem>
                      <SelectItem value="true">Yes</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
              )}
              <div className="space-y-2">
                <Label htmlFor="net">Net (CIDR)</Label>
                <Input id="net" name="net" placeholder="192.168.1.0/24" required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="comment">Comment</Label>
                <Textarea id="comment" name="comment" />
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
              {createMutation.isError && (
                <p className="text-sm text-destructive">
                  {createMutation.error instanceof ApiRequestError
                    ? createMutation.error.data.message || createMutation.error.message
                    : "Failed to create network."}
                </p>
              )}
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
            {deleteMutation.isError && (
              <p className="text-sm text-destructive">
                {deleteMutation.error instanceof ApiRequestError
                  ? deleteMutation.error.data.message || deleteMutation.error.message
                  : "Failed to delete network."}
              </p>
            )}
          </DialogContent>
        </Dialog>
      )}
    </div>
  );
}
