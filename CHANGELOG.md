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
