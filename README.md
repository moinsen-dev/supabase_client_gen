# supabase_client_gen

Contract-driven code generator for Supabase. Define your backend in a single
YAML file, then generate a complete typed Dart client — models, enums,
repositories, and edge function clients.

```bash
dart run supabase_client_gen:generate \
  --contract docs/contracts/supabase.yaml \
  --output lib/generated
```

## Why?

Writing Supabase client code by hand means repeating yourself across tables,
keeping Dart types in sync with Postgres columns, and wiring up realtime
subscriptions manually. This tool reads a single contract file — your
backend's source of truth — and produces all the Dart code you need.

**One contract. One command. Zero drift.**

## What Gets Generated

| Output | Path | Description |
|---|---|---|
| Data models | `lib/generated/models/` | Dart classes with `fromJson`/`toJson`, null-safe |
| Enums | `lib/generated/enums/` | Dart enums from Postgres enum types |
| Repositories | `lib/generated/repositories/` | Typed `.select()`, `.insert()`, `.update()`, `.delete()`, `.stream()` |
| Edge function clients | `lib/generated/edge_functions/` | Typed request/response wrappers for Supabase Edge Functions |

### Nullability Detection

With `--with-db`, the generator connects to your live Postgres database and
reads column nullability from the information schema. Generated models get
correct `?` annotations — no guessing.

## The Contract Format

A `supabase.yaml` file is the single source of truth for your backend.
Here's a complete example:

```yaml
contract:
  name: my_project_supabase_contract
  version: "0.1.0"
  date: "2026-01-01"

project:
  name: my_project
  organization: my-org
  region: eu-central-1

auth:
  provider: supabase
  planned_sign_in_methods:
    - email

roles:
  workspace_roles:
    owner:
      description: Full access to workspace
    member:
      description: Can read and write workspace data

schemas:
  public:
    exposed_to_data_api: true
    purpose: Client-facing tables
  private:
    exposed_to_data_api: false
    purpose: Internal server-side tables

data_model:
  public:
    things:
      ownership: workspace
      primary_key: id
      description: Physical and digital items users track
      fields:
        id: uuid
        workspace_id: uuid
        name: text
        category: thing_category
        manufacturer: text
        model: text
        purchase_date: date
        created_at: timestamptz
        updated_at: timestamptz
      enum_values:
        thing_category:
          - appliance
          - software
          - vehicle
          - tool
          - subscription
          - other
      client_access:
        select: member
        insert: member
        update: member
        delete: owner
      nullable_fields:
        - manufacturer
        - model
        - purchase_date

storage:
  buckets:
    user_uploads:
      public: false
      allowed_mime_types:
        - image/jpeg
        - image/png
        - application/pdf
      file_size_limit_mb: 50

edge_functions:
  ask_thing:
    auth_required: true
    purpose: Answer a question about a thing using RAG
    client_invoked: true
    required_request_fields:
      - workspace_id
      - thing_id
      - question
    optional_request_fields:
      - mode
    response_fields:
      answer: text
      sources: jsonb
      safety_class: safety_class
    writes_tables:
      - public.conversations
      - public.conversation_events

realtime:
  publication:
    name: supabase_realtime
    allowed_tables:
      - public.things
      - public.thing_sources
      - public.learning_cards
      - public.conversation_events
  invoke_edge_functions:
    - ask_thing
```

### Field Types

| Contract Type | Postgres Type | Generated Dart Type |
|---|---|---|
| `uuid` | `uuid` | `String` |
| `text` | `text` / `varchar` | `String` |
| `integer` / `int4` | `integer` | `int` |
| `bigint` / `int8` | `bigint` | `int` |
| `numeric` / `decimal` | `numeric` | `double` |
| `boolean` / `bool` | `boolean` | `bool` |
| `timestamptz` / `timestamp` | `timestamptz` | `DateTime` |
| `date` | `date` | `DateTime` |
| `jsonb` / `json` | `jsonb` | `Map<String, dynamic>` |
| `vector(N)` | `vector` | `List<double>` |
| Custom enum | User-defined enum | Named Dart enum |

## CLI Reference

### generate

```bash
dart run supabase_client_gen:generate \
  --contract <path> \       # Path to supabase.yaml
  --output <dir> \          # Output directory for generated code
  [--with-db] \             # Connect to live DB for nullability detection
  [--check]                 # Verify generated code is up to date (exit 1 if not)
```

### validate

```bash
dart run supabase_client_gen:validate \
  --contract <path> \       # Path to supabase.yaml
  --output <dir> \          # Generated code directory
  [--ts <path>] \           # Path to supabase.types.ts
  [--migrations <dir>] \    # Supabase migrations directory
  [--mode=<mode>] \         # db | types | ts | migrations | all (default)
  [--with-db] \             # Include DB nullability checks
  [--json]                  # Output as JSON
```

Four validation checks:
1. **DB ↔ Contract** — Are tables, columns, types, and enums aligned?
2. **Contract ↔ Generated Code** — Is the Dart client up to date?
3. **Contract ↔ TS Types** — Does `supabase.types.ts` match the contract?
4. **Migration Freshness** — Are there migrations newer than the contract?

## Integration with Melos

```yaml
# melos.yaml
scripts:
  gen:client:
    run: dart run supabase_client_gen:generate \
      --contract ../../docs/contracts/supabase.yaml \
      --output lib/generated --with-db

  validate:all:
    run: dart run supabase_client_gen:validate \
      --contract ../../docs/contracts/supabase.yaml \
      --output lib/generated \
      --ts ../../docs/generated/supabase.types.ts \
      --migrations ../../supabase/migrations \
      --mode=all --with-db
```

## Programmatic API

```dart
import 'package:supabase_client_gen/supabase_client_gen.dart';
import 'package:yaml/yaml.dart';

void main() {
  final yaml = loadYaml(File('supabase.yaml').readAsStringSync());
  final contract = SupabaseContract.fromYaml(yaml as Map<String, dynamic>);

  // Optionally connect to live DB for nullability
  final dbSchema = await DbSchema.fetch();

  final generator = ClientGenerator(contract, dbSchema: dbSchema);
  final files = generator.generate();

  for (final entry in files.entries) {
    File('lib/generated/${entry.key}')
      ..createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
}
```

## Generated Repository API

For a `things` table, the generated `ThingRepository` provides:

```dart
final repo = ThingRepository(client: supabase.client);

// CRUD
final things = await repo.select();           // SELECT * FROM things
final thing = await repo.selectById(id);      // SELECT * WHERE id = ?
await repo.insert(ThingInsert(...));           // INSERT INTO things
await repo.update(id, ThingUpdate(...));       // UPDATE things SET ... WHERE id = ?
await repo.delete(id);                         // DELETE FROM things WHERE id = ?

// Realtime
final stream = repo.stream();                  // Realtime subscription
stream.listen((things) => print('Updated: $things'));
```

## Generated Edge Function Client API

For an `ask_thing` edge function:

```dart
final client = AskThingClient(client: supabase.client);
final response = await client.invoke(
  workspaceId: '...',
  thingId: '...',
  question: 'How do I reset this device?',
  mode: 'text', // optional
);
print(response.answer);
print(response.safetyClass);
```
