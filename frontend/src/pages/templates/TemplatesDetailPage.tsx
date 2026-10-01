import { useEffect, useState } from "react";
import { useParams, useNavigate } from "react-router-dom";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { ArrowLeft, Save, Loader2, Trash2, Pencil, X, AlertCircle } from "lucide-react";
import { ApiRequestError } from "@/lib/api-client";
import { useServerContext } from "@/hooks/use-server-context";
import { useAuth } from "@/hooks/use-auth";
import { TEMPLATE_KINDS, canModify, type TemplateContext, type TemplateKindId } from "./templateKinds";
import { TemplateDeleteDialog } from "./TemplateDeleteDialog";
import {
  TemplateFieldInput,
  TemplateFieldLabel,
  buildScalarPayload,
  fieldInitialValues,
  type FieldValues,
} from "./TemplateFields";
import {
  TemplateEntryEditor,
  TemplateEntryList,
  cleanEntryRows,
  type EntryRow,
} from "./TemplateEntryEditor";

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="text-sm font-medium">{value || "—"}</div>
    </div>
  );
}

export default function TemplatesDetailPage({ kind }: { kind: TemplateKindId }) {
  const config = TEMPLATE_KINDS[kind];
  const { id } = useParams<{ id: string }>();
  const templateId = Number(id);
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { serverName, zoneName } = useServerContext();
  const { isSuperuser, permissions } = useAuth();

  const ctx: TemplateContext = {
    serverName,
    zoneName,
    isSuperuser,
    tmplmask: permissions?.tmplmask ?? [],
  };

  const [editing, setEditing] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [formValues, setFormValues] = useState<FieldValues>(() =>
    fieldInitialValues(config.fields)
  );
  const [entries, setEntries] = useState<EntryRow[]>([]);

  const guard =
    config.contextGuard === "zone" && (!serverName || !zoneName)
      ? "Select a server and a zone first."
      : config.contextGuard === "server" && !serverName
        ? "Select a server first."
        : null;

  const validId = Number.isFinite(templateId) && templateId > 0;

  const { data: template, isLoading } = useQuery({
    queryKey: ["templates", kind, serverName, zoneName, templateId],
    queryFn: () => config.api.get(ctx, templateId),
    enabled: !guard && validId,
  });

  useEffect(() => {
    if (!template) return;
    const next: FieldValues = {};
    for (const f of config.fields) next[f.key] = template[f.key] ?? "";
    setFormValues(next);
    if (config.entry) setEntries(template[config.entry.key] ? [...template[config.entry.key]] : []);
  }, [template, config]);

  const updateMutation = useMutation({
    mutationFn: () => {
      const payload = buildScalarPayload(config.fields, formValues);
      if (config.entry) {
        payload[config.entry.key] = cleanEntryRows(config.entry.columns, entries);
      }
      return config.api.update(ctx, templateId, payload);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["templates", kind] });
      setEditing(false);
      queryClient.invalidateQueries({
        queryKey: ["templates", kind, serverName, zoneName, templateId],
      });
    },
  });

  if (guard) {
    return (
      <div className="flex flex-col items-center justify-center py-12 text-center">
        <AlertCircle className="mb-4 h-12 w-12 text-muted-foreground" />
        <h2 className="text-xl font-semibold">Nothing Selected</h2>
        <p className="mt-1 mb-4 text-muted-foreground">{guard}</p>
        <Button onClick={() => navigate(config.listPath)}>
          Back to {config.pageTitle}
        </Button>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  if (!template) {
    return (
      <div className="flex flex-col items-center justify-center py-12">
        <h2 className="text-xl font-semibold">{config.itemNoun} not found</h2>
        <Button className="mt-4" onClick={() => navigate(config.listPath)}>
          Back to {config.pageTitle}
        </Button>
      </div>
    );
  }

  const heading = config.entry ? template.name : template.hinfo;
  const allowModify = canModify(ctx, config, template.name);
  const entryRows: EntryRow[] = config.entry ? (template[config.entry.key] ?? []) : [];

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Button variant="outline" size="icon" onClick={() => navigate(config.listPath)}>
            <ArrowLeft className="h-4 w-4" />
          </Button>
          <div>
            <h1 className="text-2xl font-bold tracking-tight">{heading}</h1>
            <p className="text-sm text-muted-foreground">
              {config.itemNoun} #{template.id}
            </p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {allowModify && !editing && (
            <>
              <Button size="sm" onClick={() => setEditing(true)}>
                <Pencil className="mr-2 h-4 w-4" />
                Edit
              </Button>
              <Button size="sm" variant="destructive" onClick={() => setDeleteOpen(true)}>
                <Trash2 className="mr-2 h-4 w-4" />
                Delete
              </Button>
            </>
          )}
          {editing && (
            <>
              <Button
                variant="outline"
                size="sm"
                onClick={() => {
                  setEditing(false);
                  const next: FieldValues = {};
                  for (const f of config.fields) next[f.key] = template[f.key] ?? "";
                  setFormValues(next);
                  if (config.entry) setEntries(entryRows);
                }}
              >
                <X className="mr-2 h-4 w-4" />
                Cancel
              </Button>
              <Button
                size="sm"
                onClick={() => updateMutation.mutate()}
                disabled={updateMutation.isPending}
              >
                {updateMutation.isPending ? (
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                ) : (
                  <Save className="mr-2 h-4 w-4" />
                )}
                Save
              </Button>
            </>
          )}
        </div>
      </div>

      {updateMutation.isError && (
        <p className="text-sm text-destructive">
          {updateMutation.error instanceof ApiRequestError
            ? updateMutation.error.data.message || updateMutation.error.message
            : `Failed to update ${config.itemNoun}.`}
        </p>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Details</CardTitle>
        </CardHeader>
        <CardContent>
          {editing ? (
            <div className="grid grid-cols-2 gap-4">
              {config.fields.map((field) => (
                <div
                  key={field.key}
                  className={field.textarea ? "col-span-2 space-y-2" : "space-y-2"}
                >
                  <TemplateFieldLabel field={field} />
                  <TemplateFieldInput
                    field={field}
                    value={formValues[field.key]}
                    onChange={(v) => setFormValues((prev) => ({ ...prev, [field.key]: v }))}
                  />
                </div>
              ))}
            </div>
          ) : (
            <div className="grid grid-cols-2 gap-4">
              <Field label="ID" value={String(template.id)} />
              {config.fields
                .filter((f) => f.key !== "comment")
                .map((field) => (
                  <Field
                    key={field.key}
                    label={field.label}
                    value={
                      field.key === "type"
                        ? String(template[field.key] ?? "")
                        : String(template[field.key] ?? "")
                    }
                  />
                ))}
              <div className="col-span-2">
                <Field label="Comment" value={template.comment ?? ""} />
              </div>
            </div>
          )}
        </CardContent>
      </Card>

      {config.entry && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">{config.entry.label}</CardTitle>
          </CardHeader>
          <CardContent>
            {editing ? (
              <TemplateEntryEditor
                columns={config.entry.columns}
                rows={entries}
                onChange={setEntries}
              />
            ) : (
              <TemplateEntryList columns={config.entry.columns} rows={entryRows} />
            )}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Record info</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-2 gap-4">
            <Field
              label="Created"
              value={
                template.cdate
                  ? `${new Date(template.cdate * 1000).toLocaleString()} by ${template.cuser ?? ""}`
                  : template.cdate_str ?? ""
              }
            />
            <Field
              label="Last modified"
              value={
                template.mdate
                  ? `${new Date(template.mdate * 1000).toLocaleString()} by ${template.muser ?? ""}`
                  : template.mdate_str ?? ""
              }
            />
          </div>
        </CardContent>
      </Card>

      <TemplateDeleteDialog
        config={config}
        ctx={ctx}
        templateId={template.id}
        templateName={template.name}
        open={deleteOpen}
        onOpenChange={setDeleteOpen}
        onDeleted={() => {
          queryClient.invalidateQueries({ queryKey: ["templates", kind] });
          navigate(config.listPath);
        }}
      />
    </div>
  );
}
