#!/usr/bin/env bash
# Round-trip compile check: generate each fixture's client code and run
# `flutter analyze` against it with real supabase_flutter / equatable deps.
# This catches valid-looking-but-non-compiling Dart that goldens would freeze.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/tool/compile_check"
FIXTURES=("edge_cases" "helpdesk")

cd "$PKG"
flutter pub get >/dev/null

status=0
for fx in "${FIXTURES[@]}"; do
  echo "── compile-check: $fx ──────────────────────────────"
  rm -rf "$PKG/lib/generated"
  dart run "$ROOT/bin/generate.dart" \
    --contract "$ROOT/test/fixtures/$fx.supabase.yaml" \
    --output "$PKG/lib/generated" >/dev/null
  if flutter analyze --no-fatal-infos lib/generated; then
    echo "  OK: $fx generated code analyses clean."
  else
    echo "  FAIL: $fx generated code did not analyse clean."
    status=1
  fi
done

rm -rf "$PKG/lib/generated"
exit $status
