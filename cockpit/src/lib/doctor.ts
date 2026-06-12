/**
 * Build-time doctor report loader.
 *
 * Reads the JSON findings file produced by
 * `dart run supabase_client_gen:doctor --contract supabase.yaml --json`
 * when the DOCTOR_REPORT environment variable is set (resolved relative to
 * the cockpit/ working directory). Without DOCTOR_REPORT the drift view
 * renders an empty state — the report is strictly optional.
 *
 * Like the contract loader, this runs only during `astro build` /
 * `astro dev` and the result is baked into static HTML.
 */
import fs from 'node:fs';
import path from 'node:path';

export type DoctorSeverity = 'error' | 'warn' | 'info';

export interface DoctorFinding {
  code: string;
  severity: DoctorSeverity;
  /** Contract path (`data_model.public.things.primary_key`) or a `db.` path. */
  path: string;
  message: string;
  fix: string;
}

export interface DoctorReport {
  /** Path the report was loaded from, for display. */
  source: string;
  findings: DoctorFinding[];
  counts: Record<DoctorSeverity, number>;
}

export const SEVERITY_ORDER: DoctorSeverity[] = ['error', 'warn', 'info'];

function asSeverity(value: unknown): DoctorSeverity {
  return value === 'error' || value === 'warn' || value === 'info' ? value : 'info';
}

let cached: DoctorReport | null | undefined;

/** Returns the parsed report, or null when DOCTOR_REPORT is not set. */
export function loadDoctorReport(): DoctorReport | null {
  if (cached !== undefined) return cached;

  const raw = process.env.DOCTOR_REPORT;
  if (!raw) {
    cached = null;
    return cached;
  }

  const resolved = path.resolve(process.cwd(), raw);
  if (!fs.existsSync(resolved)) {
    throw new Error(
      `Doctor report not found: ${resolved}\n` +
        `Generate it first, e.g.\n` +
        `  dart run supabase_client_gen:doctor --contract supabase.yaml --json > report.json`,
    );
  }

  const parsed: unknown = JSON.parse(fs.readFileSync(resolved, 'utf8'));
  if (!Array.isArray(parsed)) {
    throw new Error(
      `Doctor report must be a JSON array of findings (as emitted by doctor --json): ${resolved}`,
    );
  }

  const findings: DoctorFinding[] = parsed.map((f) => {
    const o = (f && typeof f === 'object' ? f : {}) as Record<string, unknown>;
    return {
      code: String(o.code ?? '—'),
      severity: asSeverity(o.severity),
      path: String(o.path ?? ''),
      message: String(o.message ?? ''),
      fix: String(o.fix ?? ''),
    };
  });

  const counts: Record<DoctorSeverity, number> = { error: 0, warn: 0, info: 0 };
  for (const f of findings) counts[f.severity]++;

  cached = { source: raw, findings, counts };
  return cached;
}

/**
 * Map findings onto table names for the schema graph "traffic light":
 * a finding whose path starts with `data_model.<schema>.<table>` marks that
 * table. The worst severity wins (error > warn); info findings do not
 * produce a dot. Paths that stop at the schema (`data_model.public`) or
 * point elsewhere (`db.…`, `rpc_functions.…`) are ignored.
 */
export function tableDriftStatus(
  report: DoctorReport | null,
): Record<string, 'error' | 'warn'> {
  const status: Record<string, 'error' | 'warn'> = {};
  if (!report) return status;
  for (const f of report.findings) {
    if (f.severity === 'info') continue;
    const parts = f.path.split('.');
    if (parts[0] !== 'data_model' || parts.length < 3) continue;
    const table = parts[2]!;
    if (f.severity === 'error' || status[table] !== 'error') {
      status[table] = f.severity;
    }
  }
  return status;
}
