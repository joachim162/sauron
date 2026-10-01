import { useState } from "react";
import { useQuery, useMutation } from "@tanstack/react-query";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  DialogDescription,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Loader2 } from "lucide-react";
import { ApiRequestError } from "@/lib/api-client";
import type { TemplateContext, TemplateKindConfig } from "./templateKinds";

export function TemplateDeleteDialog({
  config,
  ctx,
  templateId,
  templateName,
  open,
  onOpenChange,
  onDeleted,
}: {
  config: TemplateKindConfig;
  ctx: TemplateContext;
  templateId: number | null;
  templateName?: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onDeleted: () => void;
}) {
  const [reassignTo, setReassignTo] = useState<string>("detach");

  const { data: detail, isLoading } = useQuery({
    queryKey: ["templates", config.kind, "delete", templateId],
    queryFn: () => config.api.get(ctx, templateId!),
    enabled: open && templateId != null,
  });

  const hostCount: number = detail?.host_count ?? 0;
  const canReassign = config.reassign && !!config.api.assignable;

  const { data: assignable = [] } = useQuery({
    queryKey: ["templates", config.kind, "assignable", ctx.serverName, ctx.zoneName],
    queryFn: () => config.api.assignable!(ctx),
    enabled: open && canReassign && hostCount > 0,
  });

  const targets = assignable.filter((t) => t.id !== templateId);

  const mutation = useMutation({
    mutationFn: () =>
      config.api.delete(
        ctx,
        templateId!,
        reassignTo !== "detach" ? Number(reassignTo) : undefined
      ),
    onSuccess: () => {
      onOpenChange(false);
      onDeleted();
    },
  });

  const name = detail?.name ?? templateName ?? `#${templateId}`;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Delete {config.itemNoun}</DialogTitle>
          <DialogDescription>
            Are you sure you want to delete <strong>{name}</strong>? This cannot be undone.
          </DialogDescription>
        </DialogHeader>

        {isLoading ? (
          <p className="text-sm text-muted-foreground">
            <Loader2 className="mr-2 inline h-4 w-4 animate-spin" />
            Checking references…
          </p>
        ) : canReassign && hostCount > 0 ? (
          <div className="space-y-3">
            <p className="text-sm">
              <strong>{hostCount}</strong> host{hostCount !== 1 ? "s" : ""} use this template.
              Choose a template to move them to, or detach them.
            </p>
            <div className="space-y-2">
              <Label htmlFor="reassign">Reassign referencing hosts to</Label>
              <Select value={reassignTo} onValueChange={setReassignTo}>
                <SelectTrigger id="reassign">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="detach">Detach (leave without a template)</SelectItem>
                  {targets.map((t) => (
                    <SelectItem key={t.id} value={String(t.id)}>
                      {t.name} (level {t.alevel})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>
        ) : null}

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            variant="destructive"
            onClick={() => mutation.mutate()}
            disabled={mutation.isPending || isLoading}
          >
            {mutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
            Delete
          </Button>
        </DialogFooter>
        {mutation.isError && (
          <p className="text-sm text-destructive">
            {mutation.error instanceof ApiRequestError
              ? mutation.error.data.message || mutation.error.message
              : `Failed to delete ${config.itemNoun}.`}
          </p>
        )}
      </DialogContent>
    </Dialog>
  );
}
