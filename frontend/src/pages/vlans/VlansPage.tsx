import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useSearchParams } from "react-router-dom";
import type { ColumnDef, PaginationState } from "@tanstack/react-table";
import { vlansApi } from "@/api";
import type { VlanSummary, NewVlan } from "@/lib/types";
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
import { Textarea } from "@/components/ui/textarea";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Plus, Trash2, Loader2, AlertCircle } from "lucide-react";
import { useMemo, useState } from "react";
import { ApiRequestError } from "@/lib/api-client";

const PAGE_SIZE_OPTIONS = [10, 25, 50, 100];

export default function VlansPage() {
  const { isSuperuser } = useAuth();
  const { serverName } = useServerContext();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
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

  const [createOpen, setCreateOpen] = useState(false);
  const [deleteName, setDeleteName] = useState<string | null>(null);

  const { data: response, isLoading, isError, error } = useQuery({
    queryKey: ["vlans", serverName, pagination.pageIndex, pagination.pageSize],
    queryFn: () =>
      vlansApi.list(serverName!, {
        page: pagination.pageIndex + 1,
        per_page: pagination.pageSize,
      }),
    enabled: !!serverName,
  });

  const vlans = response?.data ?? [];
  const total = response?.metadata.pagination.total ?? vlans.length;
  const pageCount = response?.metadata.pagination.total_pages ?? 1;
  const pageSizeOptions = PAGE_SIZE_OPTIONS.includes(pagination.pageSize)
    ? PAGE_SIZE_OPTIONS
    : [...PAGE_SIZE_OPTIONS, pagination.pageSize].sort((a, b) => a - b);

  const createMutation = useMutation({
    mutationFn: (data: NewVlan) => vlansApi.create(serverName!, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["vlans", serverName] });
      setCreateOpen(false);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (name: string) => vlansApi.delete(serverName!, name),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["vlans", serverName] });
      setDeleteName(null);
    },
  });

  if (!serverName) {
    return (
      <div className="flex flex-col items-center justify-center py-12 text-center">
        <AlertCircle className="h-12 w-12 text-muted-foreground mb-4" />
        <h2 className="text-xl font-semibold">No Server Selected</h2>
        <p className="text-muted-foreground mt-1 mb-4">Select a server from the dashboard first.</p>
        <Button onClick={() => navigate("/")}>Go to Dashboard</Button>
      </div>
    );
  }

  const columns: ColumnDef<VlanSummary>[] = [
    { accessorKey: "id", header: "ID", size: 60 },
    {
      accessorKey: "name",
      header: "Name",
      cell: ({ row }) => <span className="font-medium">{row.original.name}</span>,
    },
    {
      accessorKey: "vlanno",
      header: "VLAN No.",
      size: 90,
      cell: ({ row }) => row.original.vlanno ?? "—",
    },
    {
      accessorKey: "description",
      header: "Description",
      cell: ({ row }) => row.original.description || "—",
    },
    {
      accessorKey: "comment",
      header: "Comment",
      cell: ({ row }) => row.original.comment || "—",
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
              navigate(`/vlans/${encodeURIComponent(row.original.name)}`);
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
                setDeleteName(row.original.name);
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
          <h1 className="text-2xl font-bold tracking-tight">VLANs</h1>
          <p className="text-muted-foreground">
            {serverName} — {total} VLAN{total !== 1 ? "s" : ""}
          </p>
        </div>
        {isSuperuser && (
          <Button onClick={() => setCreateOpen(true)}>
            <Plus className="mr-2 h-4 w-4" />
            Add VLAN
          </Button>
        )}
      </div>

      {isError && (
        <p className="text-sm text-destructive">
          {error instanceof ApiRequestError
            ? error.data.message || error.message
            : "Failed to load VLANs."}
        </p>
      )}

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
          data={vlans}
          isLoading={isLoading}
          pageCount={pageCount}
          pagination={pagination}
          onPaginationChange={updatePagination}
          emptyMessage="No VLANs found."
          onRowClick={(vlan) => navigate(`/vlans/${encodeURIComponent(vlan.name)}`)}
        />
      </div>

      {createOpen && (
        <Dialog open={createOpen} onOpenChange={() => setCreateOpen(false)}>
          <DialogContent className="max-w-lg">
            <DialogHeader>
              <DialogTitle>New VLAN</DialogTitle>
              <DialogDescription>Create a VLAN on {serverName}.</DialogDescription>
            </DialogHeader>
            <form
              onSubmit={(e) => {
                e.preventDefault();
                const fd = new FormData(e.currentTarget);
                const vlannoRaw = (fd.get("vlanno") as string).trim();
                createMutation.mutate({
                  name: fd.get("name") as string,
                  vlanno: vlannoRaw === "" ? null : Number(vlannoRaw),
                  description: (fd.get("description") as string) || null,
                  comment: (fd.get("comment") as string) || null,
                });
              }}
              className="space-y-4"
            >
              <div className="space-y-2">
                <Label htmlFor="name">Name</Label>
                <Input id="name" name="name" required pattern="[A-Za-z0-9_.-]+" />
              </div>
              <div className="space-y-2">
                <Label htmlFor="vlanno">VLAN No.</Label>
                <Input id="vlanno" name="vlanno" type="number" min={0} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="description">Description</Label>
                <Input id="description" name="description" />
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
                    : "Failed to create VLAN."}
                </p>
              )}
            </form>
          </DialogContent>
        </Dialog>
      )}

      {deleteName && (
        <Dialog open={!!deleteName} onOpenChange={() => setDeleteName(null)}>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Delete VLAN</DialogTitle>
              <DialogDescription>
                Are you sure you want to delete <strong>{deleteName}</strong>? Networks and VMPS
                domains referencing it are detached. This cannot be undone.
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
                  : "Failed to delete VLAN."}
              </p>
            )}
          </DialogContent>
        </Dialog>
      )}
    </div>
  );
}
