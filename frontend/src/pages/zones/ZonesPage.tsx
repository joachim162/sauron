import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useSearchParams } from "react-router-dom";
import type { ColumnDef, PaginationState } from "@tanstack/react-table";
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
import { useEffect, useMemo, useRef, useState } from "react";
import { FormHint } from "@/components/FormHint";

const PAGE_SIZE_OPTIONS = [10, 25, 50, 100];

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
  const [searchParams, setSearchParams] = useSearchParams();

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

  const prevServerRef = useRef<string | null>(serverName);
  useEffect(() => {
    if (prevServerRef.current === serverName) return;
    prevServerRef.current = serverName;
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
  }, [serverName, setSearchParams]);

  const { data: zonesResponse, isLoading } = useQuery({
    queryKey: ["zones", serverName, pagination.pageIndex, pagination.pageSize],
    queryFn: () =>
      zonesApi.list(serverName!, {
        page: pagination.pageIndex + 1,
        per_page: pagination.pageSize,
      }),
    enabled: !!serverName,
  });

  const zones = zonesResponse?.data ?? [];
  const totalZones = zonesResponse?.metadata.pagination.total ?? zones.length;
  const pageCount = zonesResponse?.metadata.pagination.total_pages ?? 1;
  const pageSizeOptions = PAGE_SIZE_OPTIONS.includes(pagination.pageSize)
    ? PAGE_SIZE_OPTIONS
    : [...PAGE_SIZE_OPTIONS, pagination.pageSize].sort((a, b) => a - b);

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
      if (zones.length === 1 && pagination.pageIndex > 0) {
        updatePagination({ ...pagination, pageIndex: pagination.pageIndex - 1 });
      }
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
            {serverName} — {totalZones} zone{totalZones !== 1 ? "s" : ""}
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
          data={zones}
          isLoading={isLoading}
          pageCount={pageCount}
          pagination={pagination}
          onPaginationChange={updatePagination}
          emptyMessage="No zones found."
          onRowClick={(zone) => {
            setZone(zone.id, zone.name);
            navigate(`/zones/${encodeURIComponent(zone.name)}`);
          }}
        />
      </div>

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
