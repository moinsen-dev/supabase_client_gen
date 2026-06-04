# Contract-Driven Supabase Client Generator

Reads a `supabase.yaml` contract and produces typed Dart client code.

## Usage

```bash
# Generate typed Dart client from contract
dart run tool/generate.dart \
  --contract docs/contracts/supabase.yaml \
  --output lib/generated

# Include DB nullability detection
dart run tool/generate.dart \
  --contract docs/contracts/supabase.yaml \
  --output lib/generated \
  --with-db

# Check if generated code is up to date
dart run tool/generate.dart \
  --contract docs/contracts/supabase.yaml \
  --output lib/generated \
  --check --with-db

# Validate everything
dart run tool/validate.dart \
  --contract docs/contracts/supabase.yaml \
  --output lib/generated \
  --ts docs/generated/supabase.types.ts \
  --migrations supabase/migrations \
  --mode=all --with-db
```

## Contract Format

See `docs/contracts/supabase.yaml` in the consuming project.

## Generated Output

- `models/` — Data classes with `fromJson`/`toJson`
- `enums/` — Dart enums from contract enum values
- `repositories/` — Typed CRUD + `.stream()` for Realtime
- `edge_functions/` — Typed edge function clients
