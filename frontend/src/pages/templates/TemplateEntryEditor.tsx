import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { X, Plus } from "lucide-react";
import type { TemplateEntryColumn } from "./templateKinds";

export interface EntryRow {
  [key: string]: string | number | null | undefined;
}

export function TemplateEntryEditor({
  columns,
  rows,
  onChange,
}: {
  columns: TemplateEntryColumn[];
  rows: EntryRow[];
  onChange: (rows: EntryRow[]) => void;
}) {
  return (
    <div className="space-y-2">
      {rows.map((row, idx) => (
        <div key={idx} className="flex items-center gap-2">
          {columns.map((col) => (
            <Input
              key={col.key}
              type={col.type === "number" ? "number" : "text"}
              className={col.width ?? "flex-1"}
              placeholder={col.placeholder ?? col.label}
              required={col.required}
              value={row[col.key] ?? ""}
              onChange={(e) => {
                const next = [...rows];
                const raw = e.target.value;
                const value =
                  col.type === "number"
                    ? raw === ""
                      ? ""
                      : Number(raw)
                    : raw;
                next[idx] = { ...next[idx], [col.key]: value };
                onChange(next);
              }}
            />
          ))}
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="h-8 w-8 shrink-0 text-destructive"
            onClick={() => onChange(rows.filter((_, i) => i !== idx))}
          >
            <X className="h-4 w-4" />
          </Button>
        </div>
      ))}
      <Button
        type="button"
        variant="outline"
        size="sm"
        onClick={() => onChange([...rows, {}])}
      >
        <Plus className="mr-2 h-4 w-4" />
        Add entry
      </Button>
    </div>
  );
}

export function TemplateEntryList({
  columns,
  rows,
}: {
  columns: TemplateEntryColumn[];
  rows: EntryRow[];
}) {
  if (!rows.length) return <p className="text-sm text-muted-foreground">None</p>;
  return (
    <div className="divide-y rounded-md border">
      {rows.map((row, idx) => (
        <div key={idx} className="flex items-center gap-4 px-3 py-2 text-sm">
          {columns.map((col) => (
            <span
              key={col.key}
              className={col.type === "number" ? "w-16 text-right" : "font-mono"}
            >
              {row[col.key] ?? ""}
            </span>
          ))}
        </div>
      ))}
    </div>
  );
}

/** Strip empty rows and coerce numeric columns before saving. */
export function cleanEntryRows(columns: TemplateEntryColumn[], rows: EntryRow[]): EntryRow[] {
  const requiredKeys = columns.filter((c) => c.required).map((c) => c.key);
  return rows
    .filter((row) =>
      requiredKeys.every((k) => {
        const v = row[k];
        return v !== undefined && v !== null && String(v).trim() !== "";
      })
    )
    .map((row) => {
      const out: EntryRow = {};
      for (const col of columns) {
        const v = row[col.key];
        if (v === undefined || v === null || String(v).trim() === "") {
          if (col.type === "number") out[col.key] = 0;
          else out[col.key] = null;
        } else {
          out[col.key] = v;
        }
      }
      return out;
    });
}
