import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import type { TemplateFieldDef } from "./templateKinds";

export type FieldValues = Record<string, string | number | null>;

export function fieldInitialValues(fields: TemplateFieldDef[]): FieldValues {
  const out: FieldValues = {};
  for (const f of fields) out[f.key] = f.defaultValue ?? "";
  return out;
}

export function buildScalarPayload(
  fields: TemplateFieldDef[],
  values: FieldValues
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const f of fields) {
    const v = values[f.key];
    if (f.type === "number") {
      out[f.key] = v === "" || v === null || v === undefined ? null : Number(v);
    } else {
      out[f.key] = v === "" || v === null || v === undefined ? null : v;
    }
  }
  return out;
}

export function TemplateFieldInput({
  field,
  value,
  onChange,
}: {
  field: TemplateFieldDef;
  value: string | number | null;
  onChange: (value: string | number) => void;
}) {
  if (field.type === "select") {
    return (
      <Select value={String(value ?? "")} onValueChange={(v) => onChange(v)}>
        <SelectTrigger id={field.key}>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {(field.options ?? []).map((o) => (
            <SelectItem key={o.value} value={o.value}>
              {o.label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    );
  }

  if (field.textarea) {
    return (
      <Textarea
        id={field.key}
        value={String(value ?? "")}
        onChange={(e) => onChange(e.target.value)}
      />
    );
  }

  return (
    <Input
      id={field.key}
      type={field.type === "number" ? "number" : "text"}
      min={field.min}
      pattern={field.pattern}
      required={field.required}
      placeholder={field.placeholder}
      value={String(value ?? "")}
      onChange={(e) => onChange(e.target.value)}
    />
  );
}

export function TemplateFieldLabel({ field }: { field: TemplateFieldDef }) {
  return (
    <Label htmlFor={field.key}>
      {field.label}
      {field.required && <span className="text-destructive"> *</span>}
    </Label>
  );
}
