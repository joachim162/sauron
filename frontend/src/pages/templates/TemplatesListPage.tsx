import { useMemo, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import type { ColumnDef, PaginationState } from "@tanstack/react-table";
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Plus, Trash2, Loader2, AlertCircle } from "lucide-react";
import { ApiRequestError } from "@/lib/api-client";
import { useServerContext } from "@/hooks/use-server-context";
import { useAuth } from "@/hooks/use-auth";
import {
  TEMPLATE_KINDS,
  canCreate,
  canModify,
  type TemplateContext,
  type TemplateKindId,
} from "./templateKinds";
import { TemplateDeleteDialog } from "./TemplateDeleteDialog";
import {
  TemplateFieldInput,
  TemplateFieldLabel,
  buildScalarPayload,
  fieldInitialValues,
} from "./TemplateFields";

const PAGE_SIZE_OPTIONS = [10, 25, 50, 100];

export default function TemplatesListPage({ kind }: { kind: TemplateKindId }) {
  const config = TEMPLATE_KINDS[kind];
  const { serverName, zoneName } = useServerContext();
  const { isSuperuser, permissions } = useAuth();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [searchParams, setSearchParams] = useSearchParams();

  const ctx: TemplateContext = {
    serverName,
    zoneName,
    isSuperuser,
    tmplmask: permissions?.tmplmask ?? [],
  };

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
  const [createValues, setCreateValues] = useState(() => fieldInitialValues(config.fields));
  const [deleteTarget, setDeleteTarget] = useState<{ id: number; name?: string } | null>(null);

  const guard =
    config.contextGuard === "zone" && (!serverName || !zoneName)
      ? "Select a server and a zone first."
      : config.contextGuard === "server" && !serverName
        ? "Select a server first."
        : null;

  const { data: response, isLoading, isError, error } = useQuery({
    queryKey: ["templates", kind, serverName, zoneName, pagination.pageIndex, pagination.pageSize],
    queryFn: () =>
      config.api.list(ctx, {
        page: pagination.pageIndex + 1,
        per_page: pagination.pageSize,
      }),
    enabled: !guard,
  });

  const rows = response?.data ?? [];
  const total = response?.metadata.pagination.total ?? rows.length;
  const pageCount = response?.metadata.pagination.total_pages ?? 1;
  const pageSizeOptions = PAGE_SIZE_OPTIONS.includes(pagination.pageSize)
    ? PAGE_SIZE_OPTIONS
    : [...PAGE_SIZE_OPTIONS, pagination.pageSize].sort((a, b) => a - b);

  const allowCreate = canCreate(ctx, config);

  const createMutation = useMutation({
    mutationFn: () => config.api.create(ctx, buildScalarPayload(config.fields, createValues)),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["templates", kind] });
      setCreateOpen(false);
      setCreateValues(fieldInitialValues(config.fields));
    },
  });

  if (guard) {
    return (
      <div className="flex flex-col items-center justify-center py-12 text-center">
        <AlertCircle className="mb-4 h-12 w-12 text-muted-foreground" />
        <h2 className="text-xl font-semibold">Nothing Selected</h2>
        <p className="mt-1 mb-4 text-muted-foreground">{guard}</p>
        <Button onClick={() => navigate("/")}>Go to Dashboard</Button>
      </div>
    );
  }

  const columns: ColumnDef<any>[] = [
    ...config.listColumns.map((c) => ({
      accessorKey: c.key,
      header: c.header,
      size: c.size,
      cell: ({ row }: { row: { original: Record<string, unknown> } }) => {
        const v = row.original[c.key];
        return (
          <span className={c.mono ? "font-mono" : undefined}>
            {v === null || v === undefined || v === "" ? "—" : String(v)}
          </span>
        );
      },
    })),
    {
      id: "actions",
      header: "",
      cell: ({ row }: { row: { original: any } }) => (
        <div className="flex items-center justify-end gap-1">
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              navigate(`${config.listPath}/${row.original.id}`);
            }}
          >
            Detail
          </Button>
          {canModify(ctx, config, row.original.name) && (
            <Button
              variant="ghost"
              size="icon"
              className="h-8 w-8 text-destructive"
              title="Delete"
              onClick={(e) => {
                e.stopPropagation();
                setDeleteTarget({ id: row.original.id, name: row.original.name });
              }}
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
          <h1 className="text-2xl font-bold tracking-tight">{config.pageTitle}</h1>
          <p className="text-muted-foreground">
            {serverName ? `${serverName} — ` : ""}
            {total} {config.itemNoun}
            {total !== 1 ? "s" : ""}
          </p>
        </div>
        {allowCreate && (
          <Button onClick={() => setCreateOpen(true)}>
            <Plus className="mr-2 h-4 w-4" />
            Add {config.itemNoun}
          </Button>
        )}
      </div>

      {isError && (
        <p className="text-sm text-destructive">
          {error instanceof ApiRequestError
            ? error.data.message || error.message
            : `Failed to load ${config.pageTitle}.`}
        </p>
      )}

      <div className="space-y-2">
        <div className="flex items-center justify-end gap-2">
          <span className="text-sm text-muted-foreground">Rows per page</span>
          <Select
            value={String(pagination.pageSize)}
            onValueChange={(v) => updatePagination({ pageIndex: 0, pageSize: Number(v) })}
          >
            <SelectTrigger className="h-8 w-24">
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
          data={rows}
          isLoading={isLoading}
          pageCount={pageCount}
          pagination={pagination}
          onPaginationChange={updatePagination}
          emptyMessage={`No ${config.pageTitle.toLowerCase()} found.`}
          onRowClick={(row: any) => navigate(`${config.listPath}/${row.id}`)}
        />
      </div>

      {createOpen && (
        <Dialog
          open={createOpen}
          onOpenChange={(o) => {
            setCreateOpen(o);
            if (!o) setCreateValues(fieldInitialValues(config.fields));
          }}
        >
          <DialogContent className="max-w-lg">
            <DialogHeader>
              <DialogTitle>New {config.itemNoun}</DialogTitle>
              <DialogDescription>
                {serverName ? `Create on ${serverName}.` : "Create a template."}
              </DialogDescription>
            </DialogHeader>
            <form
              onSubmit={(e) => {
                e.preventDefault();
                createMutation.mutate();
              }}
              className="space-y-4"
            >
              {config.fields.map((field) => (
                <div key={field.key} className="space-y-2">
                  <TemplateFieldLabel field={field} />
                  <TemplateFieldInput
                    field={field}
                    value={createValues[field.key]}
                    onChange={(v) =>
                      setCreateValues((prev) => ({ ...prev, [field.key]: v }))
                    }
                  />
                </div>
              ))}
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
                    : `Failed to create ${config.itemNoun}.`}
                </p>
              )}
            </form>
          </DialogContent>
        </Dialog>
      )}

      <TemplateDeleteDialog
        config={config}
        ctx={ctx}
        templateId={deleteTarget?.id ?? null}
        templateName={deleteTarget?.name}
        open={!!deleteTarget}
        onOpenChange={(o) => {
          if (!o) setDeleteTarget(null);
        }}
        onDeleted={() => {
          queryClient.invalidateQueries({ queryKey: ["templates", kind] });
          setDeleteTarget(null);
        }}
      />
    </div>
  );
}
