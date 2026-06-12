## 0.4.0

### Added
- **`CONTRACT.md` Markdown projection.** Every `generate` run additionally
  writes a compact, deterministic data dictionary into the output directory:
  tables (fields, nullability, `PK`/enum notes, declared `client_access`),
  RPC and edge function signatures, realtime and storage — order follows the
  contract, no timestamps, byte-identical across machines. Covered by the
  golden suite and by `generate --check` like every other generated file.
- **Top-level `summary:` contract field** (optional, Markdown string) —
  carried 1:1 into `CONTRACT.md`. The place where a human or an AI maintains
  the meaning context the structured sections cannot express.
- **Cockpit "Docs" view** — a sixth tab that renders the generator-produced
  `CONTRACT.md` (pass it via `CONTRACT_MD=path/to/CONTRACT.md` at build time;
  without it the tab shows the generate command). Includes a "Copy as
  Markdown" button that copies the raw Markdown — the fastest way to hand the
  contract to an AI or a colleague.
- **`init` CLI — brownfield import.** Draft a contract from an existing
  backend: `init --from-db --db-url <url>` introspects tables, columns, types,
  nullability, primary keys (composite → list form), views (`kind: view`),
  enums, public-schema functions (→ `rpc_functions` with `optional_args` from
  `DEFAULT`s and a conservative `returns` mapping), the realtime publication,
  and storage buckets. `init --from-gen-types <file.ts>` is the offline
  variant over a `supabase gen types` file (lossy: types approximated,
  functions name-only, no storage/realtime). Every human decision carries a
  `# TODO review` marker; the draft is self-tested against the loader and
  generator before writing; output is deterministically sorted so two runs
  produce an identical file.
- **`doctor` CLI — best-practice linter.** Contract-only rules DR001–DR009
  (missing primary key, missing `client_access`, mutations on views, unused
  `enum_values`, missing descriptions, public buckets, events outside the
  realtime publication, primary-key column not in `fields`) run without a
  database. With `--db-url`, rules DR101–DR106 compare against the live DB:
  unmanaged DB functions, contract RPCs missing in the DB, SECURITY DEFINER
  functions without pinned `search_path`, views without `security_invoker`,
  uncovered DB tables, and RLS disabled on contract tables. `--json` emits
  `{code, severity, path, message, fix}` for CI; exit 1 on errors
  (`--strict` also on warnings).
- `loadContractFromString` in the public API — parse and validate a contract
  from a YAML string (backs the init self-test).
- DB introspection (`DbSchema.fetch`) now also snapshots views, primary keys,
  callable public-schema functions, the realtime publication, storage
  buckets, RLS flags, and view `security_invoker` options.
- Gen-types parsing now captures Row column types, view columns, and enum
  values (additive; existing fields unchanged).

## 0.3.0

### Added
- **`rpc_functions` contract section** — declare Postgres functions (name,
  `args`, `optional_args`, `returns`, `description`) in the contract and get
  typed top-level Dart wrappers over `client.rpc(...)` in `rpc/rpc.dart`.
  Argument types use the same Postgres→Dart mapping as model fields; optional
  args are omitted from the call when null so `DEFAULT` values apply;
  `returns: row:<table>` / `rows:<table>` decode into the table's generated
  model. `validate --ts` now checks contract RPC functions against the
  gen-types `Functions` scope — a function missing in the DB is blocking drift.
- **Composite primary keys** — `primary_key` additionally accepts a list form
  (`primary_key: [session_id, user_id]`). Repository `update`/`delete` then take
  every key part as a required parameter and chain one `.eq()` per key column;
  `stream` declares the full key. The scalar string form is unchanged and
  produces byte-identical output.
- **Views as first-class contract entries** — a `data_model` entry may declare
  `kind: view` (default `table`). Views generate a model plus a read-only
  repository with only `select`/`stream` — insert/update/delete are never
  generated, regardless of `client_access`. Generated files are headed
  `// View: public.<name> (read-only)`.

## 0.2.1

### Changed
- `validate --mode=db` (and `--mode=all`) now exits non-zero only on **blocking**
  drift (error/warning severity). Info-level notes — e.g. an enum that exists in
  the database but no public table references — are still surfaced but no longer
  fail the check. A noisy validator is a distrusted validator.

## 0.2.0

Production-hardening release. **Generated output changes** — regenerate downstream
clients and review the diff (see "Changed" below).

### Added
- Golden/snapshot test suite plus a round-trip compile check that analyses
  generated code against real `supabase_flutter` / `equatable`.
- Friendly contract validation: malformed YAML now reports the offending path
  (e.g. `data_model.public.things.primary_key`) instead of a raw cast crash.
- `--db-url` flag (and `SUPABASE_DB_URL` env) on `generate` and `validate` to
  target any project's Postgres, not just local Supabase.
- `generate --with-db --sync-nullability` writes live-DB column nullability back
  into the contract's `nullable_fields`, keeping generation deterministic.
- Storage bucket clients: typed upload/download, public URL or signed URL per
  `public` flag, MIME and file-size validation from the contract.
- `--version` flag on both CLIs; provenance header on every generated file.

### Changed (output-affecting)
- **Deterministic output:** generation reads nullability **only** from the
  contract's `nullable_fields`. `--with-db` no longer feeds generation directly
  (it now validates / syncs). Same contract → byte-identical code on any machine.
- **`primary_key` is honoured:** `update`/`delete`/`stream` use the table's real
  primary key instead of a hardcoded `id`.
- **Structural workspace scoping:** `select`/`stream` are workspace-scoped only
  when the table actually has a `workspace_id` column (was a brittle access-string
  heuristic that mis-scoped global tables and the `workspaces` table itself).
- Read-only tables that have realtime now get a repository with a `.stream()`.

### Fixed
- `dart format` failures are surfaced loudly instead of silently producing
  mis-compared output.
- `edge_functions.runtime` scalar no longer crashes contract parsing.
- DB↔contract diff respects `nullable_fields` instead of always flagging nullable
  columns.

## 0.1.0

- Initial release.
- Contract-driven code generation from `supabase.yaml` to typed Dart.
- Data models with `fromJson`/`toJson` and null-safety.
- Enums from Postgres enum types.
- Repository classes with `.select()`, `.insert()`, `.update()`, `.delete()`, `.stream()`.
- Edge function clients with typed request/response.
- CLI tools: `generate` and `validate`.
- Optional live DB nullability detection via `--with-db`.
- Full validation pipeline: DB ↔ Contract ↔ Generated Code ↔ TS Types ↔ Migrations.
