import {
  mxTemplatesApi,
  wksTemplatesApi,
  printerClassesApi,
  hinfoTemplatesApi,
} from "@/api";
import type { PaginatedResponse } from "@/lib/types";

// ---------------------------------------------------------------------------
// Template kinds (ADR 0010). One config per kind drives the shared list/detail
// pages, mirroring the backend's kind-config design.
// ---------------------------------------------------------------------------

export type TemplateKindId = "mx" | "wks" | "printer-classes" | "hinfo";

export interface TemplateContext {
  serverName: string | null;
  zoneName: string | null;
  isSuperuser: boolean;
  tmplmask: string[];
}

export interface TemplateFieldDef {
  key: string;
  label: string;
  type: "text" | "number" | "select";
  required?: boolean;
  pattern?: string;
  min?: number;
  placeholder?: string;
  textarea?: boolean;
  options?: { value: string; label: string }[];
  defaultValue?: string | number;
}

export interface TemplateEntryColumn {
  key: string;
  label: string;
  type?: "text" | "number";
  placeholder?: string;
  required?: boolean;
  width?: string;
}

export interface TemplateListColumn {
  key: string;
  header: string;
  size?: number;
  mono?: boolean;
}

export interface AssignableTemplate {
  id: number;
  name: string;
  alevel: number;
}

export interface TemplateApi {
  list: (
    ctx: TemplateContext,
    opts: { page: number; per_page: number }
  ) => Promise<PaginatedResponse<any>>;
  get: (ctx: TemplateContext, id: number) => Promise<any>;
  create: (ctx: TemplateContext, data: Record<string, unknown>) => Promise<any>;
  update: (
    ctx: TemplateContext,
    id: number,
    data: Record<string, unknown>
  ) => Promise<any>;
  delete: (ctx: TemplateContext, id: number, reassignTo?: number) => Promise<unknown>;
  assignable?: (ctx: TemplateContext) => Promise<AssignableTemplate[]>;
}

export interface TemplateKindConfig {
  kind: TemplateKindId;
  navLabel: string;
  pageTitle: string;
  itemNoun: string;
  /** Which context the kind needs; drives the page's guard. */
  contextGuard: "zone" | "server" | "none";
  /** Mex/WKS support delete-with-reassign. */
  reassign: boolean;
  /** Write gate: MX uses tmplmask, everything else is superuser-only. */
  writeGate: "tmplmask" | "superuser";
  listPath: string;
  api: TemplateApi;
  listColumns: TemplateListColumn[];
  fields: TemplateFieldDef[];
  entry?: {
    key: string;
    label: string;
    columns: TemplateEntryColumn[];
  };
}

function strCmp(a: string, b: string) {
  return a.localeCompare(b);
}
void strCmp;

export const TEMPLATE_KINDS: Record<TemplateKindId, TemplateKindConfig> = {
  mx: {
    kind: "mx",
    navLabel: "MX Templates",
    pageTitle: "MX Templates",
    itemNoun: "MX template",
    contextGuard: "zone",
    reassign: true,
    writeGate: "tmplmask",
    listPath: "/templates/mx",
    api: {
      list: (ctx, opts) => mxTemplatesApi.list(ctx.serverName!, ctx.zoneName!, opts),
      get: (ctx, id) => mxTemplatesApi.get(ctx.serverName!, ctx.zoneName!, id),
      create: (ctx, data) => mxTemplatesApi.create(ctx.serverName!, ctx.zoneName!, data as any),
      update: (ctx, id, data) =>
        mxTemplatesApi.update(ctx.serverName!, ctx.zoneName!, id, data as any),
      delete: (ctx, id, reassignTo) =>
        mxTemplatesApi.delete(ctx.serverName!, ctx.zoneName!, id, reassignTo),
      assignable: (ctx) => mxTemplatesApi.assignable(ctx.serverName!, ctx.zoneName!),
    },
    listColumns: [
      { key: "id", header: "ID", size: 60 },
      { key: "name", header: "Name" },
      { key: "alevel", header: "Level", size: 80 },
      { key: "comment", header: "Comment" },
    ],
    fields: [
      { key: "name", label: "Name", type: "text", required: true },
      { key: "alevel", label: "Authorization level", type: "number", min: 0, defaultValue: 0 },
      { key: "comment", label: "Comment", type: "text", textarea: true },
    ],
    entry: {
      key: "mx_l",
      label: "MX entries",
      columns: [
        { key: "pri", label: "Priority", type: "number", required: true, width: "w-24" },
        { key: "mx", label: "MX", placeholder: "mail.example.com", required: true },
        { key: "comment", label: "Comment", width: "w-48" },
      ],
    },
  },

  wks: {
    kind: "wks",
    navLabel: "WKS Templates",
    pageTitle: "WKS Templates",
    itemNoun: "WKS template",
    contextGuard: "server",
    reassign: true,
    writeGate: "superuser",
    listPath: "/templates/wks",
    api: {
      list: (ctx, opts) => wksTemplatesApi.list(ctx.serverName!, opts),
      get: (ctx, id) => wksTemplatesApi.get(ctx.serverName!, id),
      create: (ctx, data) => wksTemplatesApi.create(ctx.serverName!, data as any),
      update: (ctx, id, data) => wksTemplatesApi.update(ctx.serverName!, id, data as any),
      delete: (ctx, id, reassignTo) => wksTemplatesApi.delete(ctx.serverName!, id, reassignTo),
      assignable: (ctx) => wksTemplatesApi.assignable(ctx.serverName!),
    },
    listColumns: [
      { key: "id", header: "ID", size: 60 },
      { key: "name", header: "Name" },
      { key: "alevel", header: "Level", size: 80 },
      { key: "comment", header: "Comment" },
    ],
    fields: [
      { key: "name", label: "Name", type: "text", required: true },
      { key: "alevel", label: "Authorization level", type: "number", min: 0, defaultValue: 0 },
      { key: "comment", label: "Comment", type: "text", textarea: true },
    ],
    entry: {
      key: "wks_l",
      label: "WKS entries",
      columns: [
        { key: "proto", label: "Protocol", placeholder: "tcp", required: true, width: "w-32" },
        { key: "services", label: "Services", placeholder: "smtp,http" },
        { key: "comment", label: "Comment", width: "w-48" },
      ],
    },
  },

  "printer-classes": {
    kind: "printer-classes",
    navLabel: "Printer Classes",
    pageTitle: "Printer Classes",
    itemNoun: "printer class",
    contextGuard: "none",
    reassign: false,
    writeGate: "superuser",
    listPath: "/templates/printer-classes",
    api: {
      list: (_ctx, opts) => printerClassesApi.list(opts),
      get: (_ctx, id) => printerClassesApi.get(id),
      create: (_ctx, data) => printerClassesApi.create(data as any),
      update: (_ctx, id, data) => printerClassesApi.update(id, data as any),
      delete: (_ctx, id) => printerClassesApi.delete(id),
    },
    listColumns: [
      { key: "id", header: "ID", size: 60 },
      { key: "name", header: "Name", mono: true },
      { key: "comment", header: "Comment" },
    ],
    fields: [
      { key: "name", label: "Name", type: "text", required: true, pattern: "@[a-zA-Z]+", placeholder: "@lw" },
      { key: "comment", label: "Comment", type: "text", textarea: true },
    ],
    entry: {
      key: "printer_l",
      label: "PRINTER entries",
      columns: [
        { key: "printer", label: "Printer", placeholder: ":lp=@lw", required: true },
        { key: "comment", label: "Comment", width: "w-48" },
      ],
    },
  },

  hinfo: {
    kind: "hinfo",
    navLabel: "HINFO Templates",
    pageTitle: "HINFO Templates",
    itemNoun: "HINFO template",
    contextGuard: "none",
    reassign: false,
    writeGate: "superuser",
    listPath: "/templates/hinfo",
    api: {
      list: (_ctx, opts) => hinfoTemplatesApi.list(opts),
      get: (_ctx, id) => hinfoTemplatesApi.get(id),
      create: (_ctx, data) => hinfoTemplatesApi.create(data as any),
      update: (_ctx, id, data) => hinfoTemplatesApi.update(id, data as any),
      delete: (_ctx, id) => hinfoTemplatesApi.delete(id),
    },
    listColumns: [
      { key: "id", header: "ID", size: 60 },
      { key: "hinfo", header: "HINFO", mono: true },
      { key: "type", header: "Type", size: 110 },
      { key: "pri", header: "Priority", size: 90 },
    ],
    fields: [
      { key: "hinfo", label: "HINFO", type: "text", required: true, pattern: "[A-Z0-9\\-+/]+", placeholder: "PC-PORTABLE" },
      {
        key: "type",
        label: "Type",
        type: "select",
        defaultValue: "hardware",
        options: [
          { value: "hardware", label: "Hardware" },
          { value: "software", label: "Software" },
        ],
      },
      { key: "pri", label: "Priority", type: "number", min: 0, defaultValue: 100 },
    ],
  },
};

export const TEMPLATE_KIND_ORDER: TemplateKindId[] = [
  "mx",
  "wks",
  "printer-classes",
  "hinfo",
];

/** Evaluate a tmplmask allowlist against a template name (UI gating only). */
export function tmplmaskMatches(masks: string[], name: string | undefined | null): boolean {
  if (!name) return false;
  return masks.some((re) => {
    try {
      return new RegExp(re).test(name);
    } catch {
      return false;
    }
  });
}

/** May the caller create templates of this kind? */
export function canCreate(ctx: TemplateContext, config: TemplateKindConfig): boolean {
  if (ctx.isSuperuser) return true;
  if (config.writeGate === "tmplmask") return ctx.tmplmask.length > 0;
  return false;
}

/** May the caller edit/delete this specific template? */
export function canModify(
  ctx: TemplateContext,
  config: TemplateKindConfig,
  name: string | undefined | null
): boolean {
  if (ctx.isSuperuser) return true;
  if (config.writeGate === "tmplmask") return tmplmaskMatches(ctx.tmplmask, name);
  return false;
}
