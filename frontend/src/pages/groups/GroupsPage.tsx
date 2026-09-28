import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useSearchParams } from "react-router-dom";
import type { ColumnDef, PaginationState } from "@tanstack/react-table";
import { groupsApi } from "@/api";
import type { GroupSummary, GroupType, NewGroup } from "@/lib/types";
import { GROUP_TYPES } from "@/lib/types";
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
import { useMemo, useState } from "react";
import { ApiRequestError } from "@/lib/api-client";

const PAGE_SIZE_OPTIONS = [10, 25, 50, 100];
const TYPE_OPTIONS = Object.keys(GROUP_TYPES) as GroupType[];
const NONE = "__none__";

function typeBadgeVariant(type: GroupType) {
  if (type === "custom_dhcp_class") return "outline" as const;
  if (type === "dhcp_class") return "secondary" as const;
  return "default" as const;
}

export default function GroupsPage() {
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
  const [createType, setCreateType] = useState<GroupType>("normal");
  const [deleteName, setDeleteName] = useState<string | null>(null);
  // Radix Select forbids empty-string item values; use a sentinel for "detach".
  const [reassignTo, setReassignTo] = useState<string>(NONE);

  const { data: groupsResponse, isLoading } = useQuery({
    queryKey: ["groups", serverName, pagination.pageIndex, pagination.pageSize],
    queryFn: () =>
      groupsApi.list(serverName!, {
        page: pagination.pageIndex + 1,
        per_page: pagination.pageSize,
      }),
    enabled: !!serverName,
  });

  const groups = groupsResponse?.data ?? [];
  const total = groupsResponse?.metadata.pagination.total ?? groups.length;
  const pageCount = groupsResponse?.metadata.pagination.total_pages ?? 1;
  const pageSizeOptions = PAGE_SIZE_OPTIONS.includes(pagination.pageSize)
    ? PAGE_SIZE_OPTIONS
    : [...PAGE_SIZE_OPTIONS, pagination.pageSize].sort((a, b) => a - b);

  const createMutation = useMutation({
    mutationFn: (data: NewGroup) => groupsApi.create(serverName!, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["groups", serverName] });
      setCreateOpen(false);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (name: string) =>
      groupsApi.delete(serverName!, name, reassignTo === NONE ? undefined : reassignTo),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["groups", serverName] });
      setDeleteName(null);
      setReassignTo(NONE);
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

  const columns: ColumnDef<GroupSummary>[] = [
    { accessorKey: "id", header: "ID", size: 60 },
    {
      accessorKey: "name",
      header: "Name",
      cell: ({ row }) => <span className="font-medium">{row.original.name}</span>,
    },
    {
      accessorKey: "type",
      header: "Type",
      cell: ({ row }) => (
        <Badge variant={typeBadgeVariant(row.original.type)} className="text-xs">
          {GROUP_TYPES[row.original.type] ?? row.original.type}
        </Badge>
      ),
    },
    { accessorKey: "alevel", header: "Level", size: 70 },
    {
      accessorKey: "vmps",
      header: "VMPS",
      cell: ({ row }) => row.original.vmps ?? "—",
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
              navigate(`/groups/${encodeURIComponent(row.original.name)}`);
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
          <h1 className="text-2xl font-bold tracking-tight">Host Groups</h1>
          <p className="text-muted-foreground">
            {serverName} — {total} group{total !== 1 ? "s" : ""}
          </p>
        </div>
        {isSuperuser && (
          <Button
            onClick={() => {
              setCreateType("normal");
              setCreateOpen(true);
            }}
          >
            <Plus className="mr-2 h-4 w-4" />
            Add Group
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
          data={groups}
          isLoading={isLoading}
          pageCount={pageCount}
          pagination={pagination}
          onPaginationChange={updatePagination}
          emptyMessage="No host groups found."
          onRowClick={(group) => navigate(`/groups/${encodeURIComponent(group.name)}`)}
        />
      </div>

      {/* Create dialog */}
      {createOpen && (
        <Dialog open={createOpen} onOpenChange={() => setCreateOpen(false)}>
          <DialogContent className="max-w-lg">
            <DialogHeader>
              <DialogTitle>New Host Group</DialogTitle>
              <DialogDescription>Create a new group on {serverName}.</DialogDescription>
            </DialogHeader>
            <form
              onSubmit={(e) => {
                e.preventDefault();
                const fd = new FormData(e.currentTarget);
                createMutation.mutate({
                  name: fd.get("name") as string,
                  type: createType,
                  alevel: Number(fd.get("alevel") || 0),
                  comment: (fd.get("comment") as string) || undefined,
                });
              }}
              className="space-y-4"
            >
              <div className="space-y-2">
                <Label htmlFor="name">Name</Label>
                <Input id="name" name="name" required />
              </div>
              <div className="space-y-2">
                <Label>Type</Label>
                <Select value={createType} onValueChange={(v) => setCreateType(v as GroupType)}>
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
                <Input id="alevel" name="alevel" type="number" min={0} defaultValue={0} />
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
                    : "Failed to create group."}
                </p>
              )}
            </form>
          </DialogContent>
        </Dialog>
      )}

      {/* Delete dialog */}
      {deleteName && (
        <Dialog
          open={!!deleteName}
          onOpenChange={() => {
            setDeleteName(null);
            setReassignTo(NONE);
          }}
        >
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Delete Host Group</DialogTitle>
              <DialogDescription>
                Are you sure you want to delete <strong>{deleteName}</strong>? Member hosts are
                detached unless you choose a group to move them to. This cannot be undone.
              </DialogDescription>
            </DialogHeader>
            <div className="space-y-2">
              <Label>Move member hosts to</Label>
              <Select value={reassignTo} onValueChange={setReassignTo}>
                <SelectTrigger>
                  <SelectValue placeholder="Detach (no group)" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={NONE}>Detach (no group)</SelectItem>
                  {groups
                    .filter((g) => g.name !== deleteName)
                    .map((g) => (
                      <SelectItem key={g.id} value={g.name}>
                        {g.name}
                      </SelectItem>
                    ))}
                </SelectContent>
              </Select>
            </div>
            <DialogFooter>
              <Button
                variant="outline"
                onClick={() => {
                  setDeleteName(null);
                  setReassignTo(NONE);
                }}
              >
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
                  : "Failed to delete group."}
              </p>
            )}
          </DialogContent>
        </Dialog>
      )}
    </div>
  );
}
