/**
 * Build-time contract loader.
 *
 * Reads the supabase_client_gen contract YAML pointed to by the CONTRACT
 * environment variable (relative to the cockpit/ working directory),
 * parses it once, and normalizes it into the shapes the views consume.
 *
 * This runs only during `astro build` / `astro dev` — the result is baked
 * into static HTML. No server, no database access, fully deterministic.
 */
import fs from 'node:fs';
import path from 'node:path';
import yaml from 'js-yaml';

// ---------------------------------------------------------------------------
// Normalized shapes
// ---------------------------------------------------------------------------

export interface FieldInfo {
  name: string;
  type: string;
  nullable: boolean;
  isPrimaryKey: boolean;
  /** Set when the field's type is declared in the table's enum_values. */
  enumValues: string[] | null;
}

export interface TableInfo {
  schema: string;
  name: string;
  /** `table` (default) or `view` when the contract declares `kind: view`. */
  kind: string;
  ownership: string | null;
  description: string | null;
  /** One entry for a scalar primary_key, several for the composite list form. */
  primaryKey: string[];
  fields: FieldInfo[];
  clientAccess: Record<string, string>;
}

/** A reference derived from naming conventions (foo_id → foos). */
export interface DerivedRef {
  fromTable: string;
  fromField: string;
  toTable: string;
}

export interface EdgeFunctionInfo {
  name: string;
  method: string | null;
  description: string | null;
  requiredFields: string[];
  optionalFields: string[];
}

/** Defensive support for the rpc_functions section (built in parallel). */
export interface RpcFunctionInfo {
  name: string;
  description: string | null;
  /** name → type when args is a map; bare entries when it is a list. */
  args: { name: string; type: string; optional: boolean }[];
  returns: string | null;
}

export interface RealtimeEventInfo {
  name: string;
  source: string | null;
  audience: string | null;
}

export interface BucketInfo {
  name: string;
  isPublic: boolean;
  allowedMimeTypes: string[];
  fileSizeLimitMb: number | null;
}

export interface Cockpit {
  contractName: string;
  contractVersion: string;
  contractDate: string;
  projectName: string | null;
  projectRef: string | null;
  authMethods: string[];
  tables: TableInfo[];
  refs: DerivedRef[];
  edgeFunctions: EdgeFunctionInfo[];
  edgeRuntime: string | null;
  rpcFunctions: RpcFunctionInfo[];
  realtimeTables: string[];
  realtimeEvents: RealtimeEventInfo[];
  buckets: BucketInfo[];
  /** All distinct client_access levels used, for the legend. */
  accessLevels: string[];
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

function contractPath(): string {
  const raw = process.env.CONTRACT ?? '../example/supabase.yaml';
  const resolved = path.resolve(process.cwd(), raw);
  if (!fs.existsSync(resolved)) {
    throw new Error(
      `Contract file not found: ${resolved}\n` +
        `Set the CONTRACT environment variable, e.g.\n` +
        `  CONTRACT=path/to/supabase.yaml npm run build`,
    );
  }
  return resolved;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function asStringList(value: unknown): string[] {
  return Array.isArray(value) ? value.map((v) => String(v)) : [];
}

// ---------------------------------------------------------------------------
// Reference heuristic
// ---------------------------------------------------------------------------

function pluralCandidates(base: string): string[] {
  const out = [base + 's', base, base + 'es'];
  if (base.endsWith('y')) out.push(base.slice(0, -1) + 'ies');
  return out;
}

/**
 * Resolve `foo_id` style fields to a table in the contract.
 * Tries the full base name first (`session_id` → sessions), then the last
 * underscore token (`added_by_user_id` → user → users).
 */
function resolveRefTarget(fieldName: string, tableNames: Set<string>): string | null {
  if (!fieldName.endsWith('_id')) return null;
  const base = fieldName.slice(0, -'_id'.length);
  for (const candidate of pluralCandidates(base)) {
    if (tableNames.has(candidate)) return candidate;
  }
  const tokens = base.split('_');
  if (tokens.length > 1) {
    const last = tokens[tokens.length - 1]!;
    for (const candidate of pluralCandidates(last)) {
      if (tableNames.has(candidate)) return candidate;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

function parseTables(dataModel: Record<string, unknown>): TableInfo[] {
  const tables: TableInfo[] = [];
  for (const [schema, schemaTablesRaw] of Object.entries(dataModel)) {
    const schemaTables = asRecord(schemaTablesRaw);
    for (const [tableName, defRaw] of Object.entries(schemaTables)) {
      const def = asRecord(defRaw);
      const fieldsRaw = asRecord(def.fields);
      const nullable = new Set(asStringList(def.nullable_fields));
      const enumValues = asRecord(def.enum_values);
      // primary_key is a scalar (`id`) or a list for composite keys
      // (`[session_id, user_id]`).
      const primaryKey = Array.isArray(def.primary_key)
        ? def.primary_key.map(String)
        : def.primary_key != null
          ? [String(def.primary_key)]
          : [];
      const pkSet = new Set(primaryKey);

      const fields: FieldInfo[] = Object.entries(fieldsRaw).map(([name, type]) => {
        const typeStr = String(type);
        const enums = enumValues[typeStr];
        return {
          name,
          type: typeStr,
          nullable: nullable.has(name),
          isPrimaryKey: pkSet.has(name),
          enumValues: Array.isArray(enums) ? enums.map(String) : null,
        };
      });

      const accessRaw = asRecord(def.client_access);
      const clientAccess: Record<string, string> = {};
      for (const [op, level] of Object.entries(accessRaw)) {
        clientAccess[op] = String(level);
      }

      tables.push({
        schema,
        name: tableName,
        kind: def.kind != null ? String(def.kind) : 'table',
        ownership: def.ownership != null ? String(def.ownership) : null,
        description: def.description != null ? String(def.description) : null,
        primaryKey,
        fields,
        clientAccess,
      });
    }
  }
  return tables;
}

function deriveRefs(tables: TableInfo[]): DerivedRef[] {
  const tableNames = new Set(tables.map((t) => t.name));
  const refs: DerivedRef[] = [];
  for (const table of tables) {
    for (const field of table.fields) {
      if (field.type !== 'uuid') continue;
      const target = resolveRefTarget(field.name, tableNames);
      if (target && target !== table.name) {
        refs.push({ fromTable: table.name, fromField: field.name, toTable: target });
      }
    }
  }
  return refs;
}

function parseEdgeFunctions(section: Record<string, unknown>): {
  runtime: string | null;
  functions: EdgeFunctionInfo[];
} {
  const runtime = section.runtime != null ? String(section.runtime) : null;
  const functions: EdgeFunctionInfo[] = [];
  for (const [name, defRaw] of Object.entries(section)) {
    if (name === 'runtime') continue;
    const def = asRecord(defRaw);
    functions.push({
      name,
      method: def.method != null ? String(def.method) : null,
      description: def.description != null ? String(def.description) : null,
      requiredFields: asStringList(def.required_request_fields),
      optionalFields: asStringList(def.optional_request_fields),
    });
  }
  return { runtime, functions };
}

/** rpc_functions is being added to the contract format in parallel — parse
 *  it defensively: tolerate args as a map (name → type) or a plain list. */
function parseRpcFunctions(section: Record<string, unknown>): RpcFunctionInfo[] {
  const functions: RpcFunctionInfo[] = [];
  for (const [name, defRaw] of Object.entries(section)) {
    if (name === 'runtime') continue;
    const def = asRecord(defRaw);
    const optional = new Set(asStringList(def.optional_args));
    let args: { name: string; type: string; optional: boolean }[] = [];
    if (Array.isArray(def.args)) {
      args = def.args.map((a) => ({
        name: String(a),
        type: '',
        optional: optional.has(String(a)),
      }));
    } else {
      args = Object.entries(asRecord(def.args)).map(([argName, argType]) => ({
        name: argName,
        type: String(argType),
        optional: optional.has(argName),
      }));
    }
    functions.push({
      name,
      description: def.description != null ? String(def.description) : null,
      args,
      returns: def.returns != null ? String(def.returns) : null,
    });
  }
  return functions;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

let cached: Cockpit | null = null;

export function loadCockpit(): Cockpit {
  if (cached) return cached;

  const file = contractPath();
  const doc = asRecord(yaml.load(fs.readFileSync(file, 'utf8')));

  const contract = asRecord(doc.contract);
  const remote = asRecord(asRecord(doc.project).remote);
  const auth = asRecord(doc.auth);
  const tables = parseTables(asRecord(doc.data_model));
  const refs = deriveRefs(tables);
  const edge = parseEdgeFunctions(asRecord(doc.edge_functions));
  const rpcFunctions = parseRpcFunctions(asRecord(doc.rpc_functions));

  const realtime = asRecord(doc.realtime);
  const realtimeTables = asStringList(asRecord(realtime.publication).allowed_tables);
  const realtimeEvents: RealtimeEventInfo[] = Object.entries(asRecord(realtime.events)).map(
    ([name, defRaw]) => {
      const def = asRecord(defRaw);
      return {
        name,
        source: def.source != null ? String(def.source) : null,
        audience: def.audience != null ? String(def.audience) : null,
      };
    },
  );

  const buckets: BucketInfo[] = Object.entries(asRecord(asRecord(doc.storage).buckets)).map(
    ([name, defRaw]) => {
      const def = asRecord(defRaw);
      return {
        name,
        isPublic: def.public === true,
        allowedMimeTypes: asStringList(def.allowed_mime_types),
        fileSizeLimitMb:
          def.file_size_limit_mb != null ? Number(def.file_size_limit_mb) : null,
      };
    },
  );

  const accessLevels = [
    ...new Set(tables.flatMap((t) => Object.values(t.clientAccess))),
  ].sort();

  cached = {
    contractName: contract.name != null ? String(contract.name) : 'unnamed contract',
    contractVersion: contract.version != null ? String(contract.version) : '—',
    contractDate: contract.date != null ? String(contract.date) : '—',
    projectName: remote.name != null ? String(remote.name) : null,
    projectRef: remote.ref != null ? String(remote.ref) : null,
    authMethods: asStringList(auth.planned_sign_in_methods),
    tables,
    refs,
    edgeFunctions: edge.functions,
    edgeRuntime: edge.runtime,
    rpcFunctions,
    realtimeTables,
    realtimeEvents,
    buckets,
    accessLevels,
  };
  return cached;
}

// ---------------------------------------------------------------------------
// Shared presentation helpers
// ---------------------------------------------------------------------------

/** Map an access level to a stable CSS class suffix used by the views. */
export function accessClass(level: string): string {
  if (level === 'authenticated') return 'authenticated';
  if (level === 'own_row') return 'own-row';
  if (level === 'edge_function_only') return 'edge-only';
  if (level.startsWith('member_of_')) return 'member';
  return 'other';
}
