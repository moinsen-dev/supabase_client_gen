# Landing page

Static product landing page for `supabase_client_gen` (Astro, dark theme,
system fonts, no tracking), with the [Contract Cockpit](../cockpit/) embedded
as a fully functional live demo under `/demo/`.

## Build

```bash
cd landing
npm install

# Landing only:
npm run build              # → dist/

# Landing + live demo (one deployable folder):
npm run build:full         # → dist/ with the cockpit at dist/demo/
```

`build:full` runs `scripts/build-demo.sh` after the landing build: it
generates a fresh contract-only `doctor --json` report, builds the cockpit
with `BASE_PATH=/demo/` plus a demo banner, and copies its output into
`dist/demo/`. The result is **one** static folder — landing at `/`, cockpit
at `/demo/` — deployable anywhere.

The demo shows the real backend contract of **MercyNight** (the reference
user). Override the inputs via env vars:

```bash
DEMO_CONTRACT=/path/to/supabase.yaml \
DEMO_CONTRACT_MD=/path/to/CONTRACT.md \
DEMO_DOCTOR_REPORT=/path/to/report.json \
npm run build:full
```

Without overrides the script falls back to `../example/supabase.yaml` when
the MercyNight contract is not present on the machine.

## Preview

```bash
npm run preview            # serves dist/ including /demo/
```
