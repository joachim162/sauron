import type { AmlElement, AclSummary, KeySummary } from "@/lib/types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Plus, X } from "lucide-react";

// Match-element rules editor for an ACL body (AML); mirrors the legacy
// "ACL Rules" ftype-12 editor: CIDR / ACL / Key rows with a NOT toggle,
// plus three typed add-buttons.

function blankRow(mode: number): AmlElement {
  return mode === 0
    ? { mode, ip: "", acl: null, tkey: null, op: 0, comment: "" }
    : { mode, ip: null, acl: null, tkey: null, op: 0, comment: "" };
}

export function AclMembersEditor({
  rows,
  onChange,
  acls,
  keys,
  selfId,
}: {
  rows: AmlElement[];
  onChange: (rows: AmlElement[]) => void;
  acls: AclSummary[];
  keys: KeySummary[];
  selfId?: number;
}) {
  // Nested-ACL targets: everything except this ACL itself (and any
  // server-owned ACL created after it — the API's acyclicity rule).
  const aclTargets = selfId
    ? acls.filter((a) => (a.server_id === -1 ? true : a.id < selfId))
    : acls;

  const updateRow = (idx: number, patch: Partial<AmlElement>) => {
    const next = rows.map((row, i) => (i === idx ? { ...row, ...patch } : row));
    onChange(next);
  };

  return (
    <div className="space-y-2">
      {rows.length > 0 && (
        <div className="grid grid-cols-[110px_60px_1fr_220px_36px] gap-2 px-1 text-xs font-medium text-muted-foreground">
          <span>Type</span>
          <span>Op</span>
          <span>Rule</span>
          <span>Comment</span>
          <span />
        </div>
      )}
      <div className="space-y-2">
        {rows.map((row, idx) => (
          <div key={idx} className="grid grid-cols-[110px_60px_1fr_220px_36px] gap-2 items-center">
            <Select
              value={String(row.mode)}
              onValueChange={(v) => updateRow(idx, blankRow(Number(v)))}
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="0">CIDR</SelectItem>
                <SelectItem value="1">ACL</SelectItem>
                <SelectItem value="2">Key</SelectItem>
              </SelectContent>
            </Select>

            <div className="flex items-center gap-1">
              <input
                id={`op-${idx}`}
                type="checkbox"
                checked={row.op === 1}
                onChange={(e) => updateRow(idx, { op: e.target.checked ? 1 : 0 })}
              />
              <label htmlFor={`op-${idx}`} className="text-sm">
                NOT
              </label>
            </div>

            {row.mode === 0 && (
              <Input
                value={row.ip ?? ""}
                placeholder="10.0.0.0/8"
                onChange={(e) => updateRow(idx, { ip: e.target.value })}
              />
            )}
            {row.mode === 1 && (
              <Select
                value={row.acl != null && row.acl > 0 ? String(row.acl) : ""}
                onValueChange={(v) => updateRow(idx, { acl: Number(v) })}
              >
                <SelectTrigger>
                  <SelectValue placeholder="— Select ACL —" />
                </SelectTrigger>
                <SelectContent>
                  {aclTargets.map((a) => (
                    <SelectItem key={a.id} value={String(a.id)}>
                      {a.name}
                      {a.builtin ? " (built-in)" : ""}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
            {row.mode === 2 && (
              <Select
                value={row.tkey != null && row.tkey > 0 ? String(row.tkey) : ""}
                onValueChange={(v) => updateRow(idx, { tkey: Number(v) })}
              >
                <SelectTrigger>
                  <SelectValue placeholder="— Select key —" />
                </SelectTrigger>
                <SelectContent>
                  {keys.map((k) => (
                    <SelectItem key={k.id} value={String(k.id)}>
                      {k.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}

            <Input
              value={row.comment ?? ""}
              placeholder="comment"
              onChange={(e) => updateRow(idx, { comment: e.target.value })}
            />

            <Button
              type="button"
              variant="ghost"
              size="icon"
              className="h-8 w-8 text-destructive"
              onClick={() => onChange(rows.filter((_, i) => i !== idx))}
            >
              <X className="h-4 w-4" />
            </Button>
          </div>
        ))}
      </div>

      <div className="flex gap-2">
        <Button type="button" variant="outline" size="sm" onClick={() => onChange([...rows, blankRow(0)])}>
          <Plus className="mr-2 h-4 w-4" />
          Add CIDR
        </Button>
        <Button type="button" variant="outline" size="sm" onClick={() => onChange([...rows, blankRow(1)])}>
          <Plus className="mr-2 h-4 w-4" />
          Add ACL
        </Button>
        <Button type="button" variant="outline" size="sm" onClick={() => onChange([...rows, blankRow(2)])}>
          <Plus className="mr-2 h-4 w-4" />
          Add Key
        </Button>
      </div>
    </div>
  );
}

export function AclMembersList({
  rows,
  aclNameById,
  keyNameById,
}: {
  rows: AmlElement[];
  aclNameById: Map<number, string>;
  keyNameById: Map<number, string>;
}) {
  if (!rows.length) return <p className="text-sm text-muted-foreground">No rules</p>;

  const ruleText = (row: AmlElement): string => {
    if (row.mode === 0) return row.ip ?? "";
    if (row.mode === 1) return aclNameById.get(row.acl ?? -1) ?? `ACL #${row.acl}`;
    return keyNameById.get(row.tkey ?? -1) ?? `Key #${row.tkey}`;
  };

  return (
    <div className="divide-y rounded-md border">
      <div className="grid grid-cols-[80px_40px_1fr_220px] gap-2 px-3 py-2 text-xs font-medium text-muted-foreground">
        <span>Type</span>
        <span>Op</span>
        <span>Rule</span>
        <span>Comment</span>
      </div>
      {rows.map((row, idx) => (
        <div key={idx} className="grid grid-cols-[80px_40px_1fr_220px] gap-2 px-3 py-2 text-sm">
          <span>{row.mode === 0 ? "CIDR" : row.mode === 1 ? "ACL" : "Key"}</span>
          <span>{row.op === 1 ? "!" : ""}</span>
          <span className="font-mono">{ruleText(row)}</span>
          <span className="text-muted-foreground">{row.comment || ""}</span>
        </div>
      ))}
    </div>
  );
}
