/// Contract-driven code generator for Supabase projects.
///
/// Reads a `supabase.yaml` contract and produces typed Dart client code:
/// - Data models with `fromJson`/`toJson`
/// - Enums
/// - Repository classes with `.select()`, `.insert()`, `.update()`, `.delete()`, `.stream()`
/// - Edge function clients with typed request/response
library supabase_client_gen;

export 'src/contract.dart';
export 'src/generator.dart';
export 'src/db_schema.dart';
export 'src/diff.dart';
export 'src/gen_types.dart';
