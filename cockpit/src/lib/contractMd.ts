/**
 * Build-time loader for the generator-produced CONTRACT.md.
 *
 * The Markdown projection is emitted by `supabase_client_gen:generate` into
 * the output directory — the cockpit never re-derives it (one emitter, no
 * duplication). When the CONTRACT_MD environment variable is set (resolved
 * relative to the cockpit/ working directory), the Docs view renders that
 * file; without it the view shows an empty state with the generate command.
 *
 * Like the contract and doctor loaders, this runs only during `astro build` /
 * `astro dev` and the result is baked into static HTML.
 */
import fs from 'node:fs';
import path from 'node:path';

export interface ContractMd {
  /** Path the markdown was loaded from, for display. */
  source: string;
  /** Raw markdown, exactly as the generator wrote it. */
  markdown: string;
}

let cached: ContractMd | null | undefined;

/** Returns the raw CONTRACT.md, or null when CONTRACT_MD is not set. */
export function loadContractMd(): ContractMd | null {
  if (cached !== undefined) return cached;

  const raw = process.env.CONTRACT_MD;
  if (!raw) {
    cached = null;
    return cached;
  }

  const resolved = path.resolve(process.cwd(), raw);
  if (!fs.existsSync(resolved)) {
    throw new Error(
      `CONTRACT.md not found: ${resolved}\n` +
        `Generate it first, e.g.\n` +
        `  dart run supabase_client_gen:generate --contract supabase.yaml --output lib/generated`,
    );
  }

  cached = { source: raw, markdown: fs.readFileSync(resolved, 'utf8') };
  return cached;
}
