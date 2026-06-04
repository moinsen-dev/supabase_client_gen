# Vision — the north star

> One declarative product truth. Every platform projected from it. Consistency
> proven continuously. Operable by humans *and* agents.

This document is the compass every future feature is checked against. It is not a
roadmap and not a promise of dates — it is the shape of the thing we are building
toward, and the principles that keep us on course while we get there.

## The reframe

Stop seeing the contract as a config file for a code generator.

The `supabase.yaml` contract is the **canonical description of a product's
backend**. Everything else — the database schema, the security model, the Dart
and TypeScript clients, the edge functions, the docs, the tests, the infra — is a
**projection** of that one truth. One source, many projections, each one
generated and continuously proven consistent with the others.

The day the contract stops describing *code* and starts describing a *product* —
from which people and agents project the whole stack and keep it provably in
sync — this stops being a generator and becomes a category.

## What we are (and are not)

- We are **not** a backend framework. Serverpod owns "Dart end-to-end" with its
  own server, ORM, and hosting. We don't rebuild that.
- Supabase **is** the backend — managed Postgres, PostgREST, Realtime, Storage,
  Edge Functions, Auth. We ride it.
- We are the **contract-driven developer-experience layer** that Supabase itself
  lacks: typed, multi-target, drift-proof, agent-operable.

The sharper framing: **Prisma + tRPC for the Supabase + Flutter (and TypeScript)
stack** — with managed Supabase underneath instead of a self-hosted server.

## Principles — the invariants

Every emitter, every feature, every release is checked against these. If a change
breaks one of them, the change is wrong, not the principle.

1. **The contract is sacred and singular.** There is exactly one source of truth.
   Generated code is never hand-edited; it carries a do-not-edit header. If a fact
   about the backend isn't in the contract, it doesn't exist.
2. **Determinism is non-negotiable.** The same contract produces byte-identical
   output on any machine, regardless of whether a database is reachable. Ambient
   state never leaks into generation.
3. **Every projection is proven.** New emitters ship with golden snapshots *and*
   a round-trip compile/validity check against real dependencies. "It generated"
   is not "it works."
4. **Drift is detectable before it ships.** Database, contract, generated code,
   and types are reconcilable at all times, and CI can gate on it.
5. **Breaking output is a versioned, visible event.** Generated code is a public
   API with semver. Output-shape changes are stamped, changelogged, and surface
   as failing `--check` in every downstream repo — never as a silent runtime break.
6. **Errors explain themselves.** A malformed contract names the offending path,
   not a stack trace. The tool is pointed at many hand-edited files; that is the
   normal case, not the exception.
7. **Backend changes are proposed, never auto-applied.** Anything that mutates a
   database (migrations, RLS) is emitted for human review and applied through the
   official tooling. We optimise for safety over magic.
8. **Scope discipline is the hard part.** The base is solid enough that almost
   everything below is a few focused sessions, not a quarter. The danger is
   building it all at once. One emitter at a time, each behind the safety net.

## The horizons

A map of what becomes possible — not an ordering, not a commitment. Each is a
projection of the same contract.

### H1 — Everything radiates from the contract
- **Clients:** Dart/Flutter (done), TypeScript (Web / Expo / Next admin), later
  native Kotlin/Swift, Python for data scripts.
- **Backend:** SQL schema, indexes, triggers, RLS policies, grants, realtime
  publication, storage policies, auth config.
- **Edge functions:** Deno scaffold (parsing, typed request/response, auth check)
  *and* the typed client on both ends — end-to-end type safety from tap to handler.
- **Docs:** ERD diagram, data dictionary, API docs — generated, never stale.
- **Tests & wiring:** in-memory repository fakes, seed data, contract tests,
  golden API responses, Riverpod/BLoC provider wiring.

### H2 — The inversion: the backend becomes an output
The contract generates the backend, not the other way around. `client_access`
*is* the security model → RLS policies fall out of it. `ownership`, `unique`,
`enum_values` → schema and constraints. The drift logic that detects deltas today
emits migrations tomorrow. Because the contract is versioned, a migration between
any two contract versions is derivable: **backend semver — git for the shape of
your backend.**

### H3 — Security as a first-class output
Declare the security model in the contract; the tool proves the database enforces
it. `things.select = member_of_workspace` → the RLS policy that enforces it → the
test that proves an outsider cannot read it. Tag fields (`pii`, `secret`) and get
audits for free: "every table with PII", "no public bucket holds PII", "every
workspace table has a workspace RLS policy." Supabase RLS is famously error-prone;
this is a real, under-served problem.

### H4 — The fleet and the timeline
A dashboard across *all* projects: every contract, every CI status, one fleet
view. "Prod diverged from contract on the 12th." Schema version history,
who-changed-what, compliance on demand. Plus a `doctor`/linter that encodes
Supabase best practices. This is the Serverpod-Insights analog — but
cross-project, because the contract format is the same everywhere.

### H5 — The agentic full-stack substrate
The contract is a compact, structured backend representation an LLM reads and
writes perfectly. "Add an invoices table with line items" → an agent edits the
contract → regenerates schema + RLS + client + tests → golden, compile, and
validate are the guardrails. The contract is the shared truth between front-end
and back-end agents. This tool is not something you use — it is the **rails your
agents run on**, making autonomous full-stack work deterministic and safe without
breaking the backend↔frontend boundary.

### H6 — Ecosystem and business
A plugin architecture (contract = stable IDL, emitters = a marketplace, like
protoc/Prisma generators). An OSS core with a hosted governance layer as the
commercial surface (the Prisma model). It rides Supabase's growth into the
under-served Flutter+Supabase tooling gap — the chance to become *the* way to
build Flutter on Supabase. Or it stays an internal superpower that ships
full-stack apps faster than anyone.

### H7 — Beyond Supabase
The contract abstraction is not intrinsically Supabase. The same IDL could target
Postgres + PostgREST directly, Appwrite, Firebase, or a custom backend. The
contract becomes a **backend description language**; Supabase is simply the first
target. (Scope dragon lives here — noted, not chased.)

## The bet

Serverpod won "Dart end-to-end." The larger, still-open bet is:

> **one declarative product truth, every platform, continuously proven — and
> agent-operable.**

Supabase hands us the managed backend for free. Nobody is occupying this space
yet. The base is solid. The discipline is to build it one proven projection at a
time, and to keep the contract sacred.
