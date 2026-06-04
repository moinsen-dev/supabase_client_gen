import 'package:supabase_client_gen/src/contract.dart';
import 'package:supabase_client_gen/src/contract_loader.dart';
import 'package:supabase_client_gen/src/db_schema.dart';
import 'package:supabase_client_gen/src/diff.dart';
import 'package:test/test.dart';

/// A minimal contract with a single public table `things(id uuid, name text)`.
SupabaseContract _contract() =>
    loadContract('test/fixtures/diff_min.supabase.yaml');

DbSchema _db(List<DbColumn> thingsCols,
        {Map<String, List<String>> enums = const {}}) =>
    DbSchema(
      tables: {'things': DbTable(name: 'things', columns: thingsCols)},
      enumValues: enums,
    );

DbColumn _col(String name, String type, {bool nullable = false}) => DbColumn(
      name: name,
      dataType: type,
      udtName: type,
      isNullable: nullable,
    );

void main() {
  test('aligned schema is clean and non-blocking', () {
    final diff = diffSchema(
      _db([_col('id', 'uuid'), _col('name', 'text')]),
      _contract(),
    );
    expect(diff.isClean, isTrue);
    expect(diff.hasBlocking, isFalse);
  });

  test('an unreferenced DB enum is info-only — surfaced but not blocking', () {
    final diff = diffSchema(
      _db([
        _col('id', 'uuid'),
        _col('name', 'text')
      ], enums: {
        'mood': ['happy', 'sad']
      }),
      _contract(),
    );
    expect(diff.isClean, isFalse); // a note exists
    expect(diff.hasBlocking, isFalse); // but it does not block
    expect(diff.blocking, isEmpty);
  });

  test('a missing column is a blocking error', () {
    final diff = diffSchema(
      _db([_col('id', 'uuid')]), // contract expects `name` too
      _contract(),
    );
    expect(diff.hasBlocking, isTrue);
    expect(diff.blocking.any((e) => e.severity == DiffSeverity.error), isTrue);
  });

  test('an extra DB column is a blocking warning', () {
    final diff = diffSchema(
      _db([_col('id', 'uuid'), _col('name', 'text'), _col('extra', 'text')]),
      _contract(),
    );
    expect(diff.hasBlocking, isTrue);
  });
}
