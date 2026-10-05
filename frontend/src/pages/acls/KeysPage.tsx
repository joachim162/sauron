import { useQuery } from "@tanstack/react-query";
import { useNavigate, useSearchParams } from "react-router-dom";
import type { ColumnDef, PaginationState } from "@tanstack/react-table";
import { keysApi } from "@/api";
import type { KeySummary } from "@/lib/types";
import { useServerContext } from "@/hooks/use-server-context";
import { DataTable } from "@/components/DataTable";
import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { AlertCircle } from "lucide-react";
import { useMemo } from "react";
import { ApiRequestError } from "@/lib/api-client";

const PAGE_SIZE_OPTIONS = [10, 25, 50, 100];

const ALGORITHM_NAMES: Record<number, string> = {
  157: "HMAC-MD5",
  158: "HMAC-SHA1",
  159: "HMAC-SHA256",
  160: "HMAC-SHA384",
  161: "HMAC-SHA512",
};

export default function KeysPage() {
  const { serverName } = useServerContext();
  const navigate = useNavigate();
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

  const { data: response, isLoading, isError, error } = useQuery({
    queryKey: ["keys", serverName, pagination.pageIndex, pagination.pageSize],
    queryFn: () =>
      keysApi.list(serverName!, {
        page: pagination.pageIndex + 1,
        per_page: pagination.pageSize,
      }),
    enabled: !!serverName,
  });

  const keys = response?.data ?? [];
  const total = response?.metadata.pagination.total ?? keys.length;
  const pageCount = response?.metadata.pagination.total_pages ?? 1;
  const pageSizeOptions = PAGE_SIZE_OPTIONS.includes(pagination.pageSize)
    ? PAGE_SIZE_OPTIONS
    : [...PAGE_SIZE_OPTIONS, pagination.pageSize].sort((a, b) => a - b);

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

  const columns: ColumnDef<KeySummary>[] = [
    { accessorKey: "id", header: "ID", size: 60 },
    {
      accessorKey: "name",
      header: "Name",
      cell: ({ row }) => <span className="font-medium">{row.original.name}</span>,
    },
    {
      accessorKey: "algorithm",
      header: "Algorithm",
      cell: ({ row }) => ALGORITHM_NAMES[row.original.algorithm ?? -1] ?? row.original.algorithm ?? "—",
    },
    {
      accessorKey: "keysize",
      header: "Key size",
      size: 90,
      cell: ({ row }) => row.original.keysize ?? "—",
    },
    {
      accessorKey: "mode",
      header: "Mode",
      cell: ({ row }) => (row.original.mode === 1 ? "Manual (Static)" : "Automatic"),
    },
    {
      id: "generated",
      header: "Key generated",
      cell: ({ row }) => row.original.mdate_str || row.original.cdate_str || "—",
    },
    {
      accessorKey: "comment",
      header: "Comment",
      cell: ({ row }) => row.original.comment || "—",
    },
  ];

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Keys</h1>
        <p className="text-muted-foreground">
          {serverName} — {total} TSIG key{total !== 1 ? "s" : ""}. Keys are managed by the keygen
          CLI; this view is read-only.
        </p>
      </div>

      {isError && (
        <p className="text-sm text-destructive">
          {error instanceof ApiRequestError
            ? error.data.message || error.message
            : "Failed to load keys."}
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
          data={keys}
          isLoading={isLoading}
          pageCount={pageCount}
          pagination={pagination}
          onPaginationChange={updatePagination}
          emptyMessage="No keys found."
        />
      </div>
    </div>
  );
}
