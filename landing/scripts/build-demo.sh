#!/usr/bin/env bash
# Build the Contract Cockpit as the landing page's live demo and copy it
# into landing/dist/demo/. Run after `astro build` (use `npm run build:full`).
#
# Configuration (env vars, all optional):
#   DEMO_CONTRACT      contract YAML the demo shows
#                      default: MercyNight's real contract if present,
#                      otherwise ../example/supabase.yaml
#   DEMO_CONTRACT_MD   generated CONTRACT.md for the Docs view (optional)
#   DEMO_DOCTOR_REPORT pre-built doctor --json report; when unset the script
#                      generates a fresh contract-only report via dart
set -euo pipefail

LANDING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$LANDING_DIR/.." && pwd)"
COCKPIT_DIR="$REPO_DIR/cockpit"

# --- Resolve the demo contract -------------------------------------------
MERCY_ROOT="$HOME/work/moinsen/ideas/together_2025/mercy_night"
DEFAULT_CONTRACT="$MERCY_ROOT/docs/contracts/supabase.yaml"
DEFAULT_CONTRACT_MD="$MERCY_ROOT/lib/generated/CONTRACT.md"

CONTRACT_PATH="${DEMO_CONTRACT:-}"
if [[ -z "$CONTRACT_PATH" ]]; then
  if [[ -f "$DEFAULT_CONTRACT" ]]; then
    CONTRACT_PATH="$DEFAULT_CONTRACT"
  else
    CONTRACT_PATH="$REPO_DIR/example/supabase.yaml"
    echo "demo: MercyNight contract not found, falling back to example contract"
  fi
fi
echo "demo: contract = $CONTRACT_PATH"

CONTRACT_MD_PATH="${DEMO_CONTRACT_MD:-}"
if [[ -z "$CONTRACT_MD_PATH" && -f "$DEFAULT_CONTRACT_MD" ]]; then
  CONTRACT_MD_PATH="$DEFAULT_CONTRACT_MD"
fi
[[ -n "$CONTRACT_MD_PATH" ]] && echo "demo: contract md = $CONTRACT_MD_PATH"

# --- Doctor report (contract-only lint, DR0xx) ----------------------------
DOCTOR_PATH="${DEMO_DOCTOR_REPORT:-}"
if [[ -z "$DOCTOR_PATH" ]]; then
  if command -v dart >/dev/null 2>&1; then
    DOCTOR_PATH="$LANDING_DIR/.astro-demo-doctor.json"
    mkdir -p "$LANDING_DIR"
    # Doctor exits 1 on errors — the report is what we want either way.
    (cd "$REPO_DIR" && dart run bin/doctor.dart \
      --contract "$CONTRACT_PATH" --json > "$DOCTOR_PATH") || true
    echo "demo: doctor report generated → $DOCTOR_PATH"
  else
    echo "demo: dart not found, building without a doctor report"
  fi
fi

# --- Build the cockpit under /demo/ ---------------------------------------
if [[ ! -d "$COCKPIT_DIR/node_modules" ]]; then
  echo "demo: installing cockpit dependencies"
  (cd "$COCKPIT_DIR" && npm install --no-fund --no-audit)
fi

(cd "$COCKPIT_DIR" && \
  BASE_PATH=/demo/ \
  CONTRACT="$CONTRACT_PATH" \
  CONTRACT_MD="$CONTRACT_MD_PATH" \
  DOCTOR_REPORT="$DOCTOR_PATH" \
  DEMO_BANNER="Demo: the real backend contract of MercyNight, a party-music app" \
  DEMO_BANNER_HREF="/" \
  npx astro build)

# --- Merge into the landing dist ------------------------------------------
if [[ ! -d "$LANDING_DIR/dist" ]]; then
  echo "demo: landing/dist missing — run 'npm run build' first (or use build:full)" >&2
  exit 1
fi
rm -rf "$LANDING_DIR/dist/demo"
mkdir -p "$LANDING_DIR/dist/demo"
cp -R "$COCKPIT_DIR/dist/." "$LANDING_DIR/dist/demo/"
echo "demo: cockpit copied → landing/dist/demo/"
echo "demo: done — deploy landing/dist as one static site"
