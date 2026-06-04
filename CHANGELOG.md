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
