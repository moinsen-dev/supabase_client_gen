/// Brownfield-import tests: a database snapshot (or gen-types file) must
/// round-trip into a contract draft that (a) matches its golden byte-for-byte,
/// (b) passes the strict contract loader, and (c) runs through the generator.
///
/// To intentionally update goldens after a reviewed emitter change:
///   UPDATE_GOLDENS=1 dart test test/init_test.dart
library;

import 'dart:io';

import 'package:supabase_client_gen/src/contract_init.dart';
import 'package:supabase_client_gen/src/contract_loader.dart';
import 'package:supabase_client_gen/src/db_schema.dart';
import 'package:supabase_client_gen/src/gen_types.dart';
import 'package:supabase_client_gen/src/generator.dart';
import 'package:test/test.dart';

/// A hand-built snapshot standing in for a live introspection — covers
/// composite PKs, enums, views, functions with defaults/SETOF, realtime,
/// and storage buckets.
DbSchema _fakeDb() => DbSchema(
      tables: {
        'things': DbTable(name: 'things', columns: [
          const DbColumn(
              name: 'id', dataType: 'uuid', udtName: 'uuid',
              isNullable: false),
          const DbColumn(
              name: 'workspace_id', dataType: 'uuid', udtName: 'uuid',
              isNullable: false),
          const DbColumn(
              name: 'name', dataType: 'text', udtName: 'text',
              isNullable: false),
          const DbColumn(
              name: 'category', dataType: 'USER-DEFINED',
              udtName: 'thing_category', isNullable: false),
          const DbColumn(
              name: 'notes', dataType: 'text', udtName: 'text',
              isNullable: true),
          const DbColumn(
              name: 'tags', dataType: 'ARRAY', udtName: '_text',
              isNullable: true),
          const DbColumn(
              name: 'location', dataType: 'USER-DEFINED', udtName: 'geometry',
              isNullable: true),
          const DbColumn(
              name: 'created_at', dataType: 'timestamp with time zone',
              udtName: 'timestamptz', isNullable: false),
        ]),
        'session_players': DbTable(name: 'session_players', columns: [
          const DbColumn(
              name: 'session_id', dataType: 'uuid', udtName: 'uuid',
              isNullable: false),
          const DbColumn(
              name: 'user_id', dataType: 'uuid', udtName: 'uuid',
              isNullable: false),
          const DbColumn(
              name: 'score', dataType: 'integer', udtName: 'int4',
              isNullable: false),
        ]),
      },
      views: {
        'things_overview': DbTable(name: 'things_overview', columns: [
          const DbColumn(
              name: 'id', dataType: 'uuid', udtName: 'uuid', isNullable: true),
          const DbColumn(
              name: 'name', dataType: 'text', udtName: 'text',
              isNullable: true),
          const DbColumn(
              name: 'note_count', dataType: 'bigint', udtName: 'int8',
              isNullable: true),
        ]),
      },
      enumValues: {
        'thing_category': ['device', 'document', 'other'],
      },
      primaryKeys: {
        'things': ['id'],
        'session_players': ['session_id', 'user_id'],
      },
      functions: {
        'add_thing_note': DbFunction.parse(
          name: 'add_thing_note',
          argumentSignature:
              'p_thing_id uuid, p_note text, p_pinned boolean DEFAULT false',
          returnSignature: 'uuid',
          isSecurityDefiner: false,
          hasSearchPath: false,
        ),
        'list_things': DbFunction.parse(
          name: 'list_things',
          argumentSignature: 'p_workspace_id uuid',
          returnSignature: 'SETOF things',
          isSecurityDefiner: true,
          hasSearchPath: true,
        ),
        'get_stats': DbFunction.parse(
          name: 'get_stats',
          argumentSignature: '',
          returnSignature: 'TABLE(total bigint, open bigint)',
          isSecurityDefiner: false,
          hasSearchPath: false,
        ),
      },
      realtimeTables: {'things'},
      storageBuckets: [
        const DbBucket(
          name: 'avatars',
          public: true,
          fileSizeLimitBytes: 5 * 1024 * 1024,
          allowedMimeTypes: ['image/png', 'image/jpeg'],
        ),
      ],
      rlsEnabled: {'things': true, 'session_players': true},
    );

void main() {
  final update = Platform.environment['UPDATE_GOLDENS'] == '1';

  void goldenCheck(String name, String draft) {
    final goldenFile = File('test/goldens/init/$name');
    if (update) {
      goldenFile
        ..createSync(recursive: true)
        ..writeAsStringSync(draft);
      return;
    }
    expect(goldenFile.existsSync(), isTrue,
        reason: 'Missing golden ${goldenFile.path} — run with '
            'UPDATE_GOLDENS=1');
    expect(draft, equals(goldenFile.readAsStringSync()),
        reason: 'Draft drift in $name — review and run UPDATE_GOLDENS=1 if '
            'intended');
  }

  group('init --from-db', () {
    final draft = buildContractFromDb(_fakeDb(),
        projectName: 'demo', date: '2026-06-12');

    test('matches golden', () => goldenCheck('from_db.supabase.yaml', draft));

    test('is deterministic', () {
      final again = buildContractFromDb(_fakeDb(),
          projectName: 'demo', date: '2026-06-12');
      expect(again, equals(draft));
    });

    test('round-trips through loader and generator', () {
      final contract = loadContractFromString(draft, sourceName: 'draft');
      final files = ClientGenerator(contract).generate();
      expect(files, isNotEmpty);
      expect(contract.publicTables.keys,
          containsAll(['things', 'session_players', 'things_overview']));
    });

    test('preserves composite primary keys as a list', () {
      final contract = loadContractFromString(draft);
      expect(contract.publicTables['session_players']!.primaryKey,
          equals(['session_id', 'user_id']));
    });

    test('marks views and keeps them read-only', () {
      final contract = loadContractFromString(draft);
      expect(contract.publicTables['things_overview']!.isView, isTrue);
      expect(draft, isNot(contains('things_overview:\n      insert')));
    });

    test('maps function defaults to optional_args and SETOF to rows:', () {
      final contract = loadContractFromString(draft);
      final addNote = contract.rpcFunctions!['add_thing_note']!;
      expect(addNote.args.keys,
          equals(['p_note', 'p_pinned', 'p_thing_id']));
      expect(addNote.optionalArgs, equals(['p_pinned']));
      expect(addNote.returns, equals('uuid'));
      expect(contract.rpcFunctions!['list_things']!.returns,
          equals('rows:things'));
      // TABLE(...) results fall back to json — conservative by design.
      expect(contract.rpcFunctions!['get_stats']!.returns, equals('json'));
    });

    test('unmapped column types fall back to text with a TODO marker', () {
      expect(
          draft,
          contains(
              "location: text # TODO review: unmapped Postgres type 'geometry'"));
    });

    test('carries realtime publication and storage buckets', () {
      final contract = loadContractFromString(draft);
      expect(contract.realtimePublicTables, equals({'things'}));
      final bucket = contract.storage!.buckets['avatars']!;
      expect(bucket.public, isTrue);
      expect(bucket.fileSizeLimitMb, equals(5));
      expect(bucket.allowedMimeTypes, equals(['image/jpeg', 'image/png']));
    });

    test('guesses workspace ownership from a workspace_id column', () {
      final contract = loadContractFromString(draft);
      expect(contract.publicTables['things']!.ownership, equals('workspace'));
      expect(contract.publicTables['session_players']!.ownership,
          equals('global'));
    });
  });

  group('init --from-gen-types', () {
    final ts = File('test/fixtures/init.types.ts').readAsStringSync();
    final draft = buildContractFromGenTypes(GenTypes.parse(ts),
        projectName: 'demo', date: '2026-06-12');

    test('matches golden',
        () => goldenCheck('from_gen_types.supabase.yaml', draft));

    test('round-trips through loader and generator', () {
      final contract = loadContractFromString(draft, sourceName: 'draft');
      final files = ClientGenerator(contract).generate();
      expect(files, isNotEmpty);
      expect(contract.publicTables.keys,
          containsAll(['sessions', 'workspace_notes', 'session_overview']));
    });

    test('recovers enum values in their declared order', () {
      final contract = loadContractFromString(draft);
      expect(contract.publicTables['sessions']!.enumValues!['session_status'],
          equals(['lobby', 'active', 'ended']));
    });

    test('derives nullability from `| null` Row types', () {
      final contract = loadContractFromString(draft);
      expect(contract.publicTables['sessions']!.nullableFields,
          equals(['started_at']));
      expect(contract.publicTables['workspace_notes']!.nullableFields,
          equals(['body', 'tags']));
    });

    test('declares views with kind: view', () {
      final contract = loadContractFromString(draft);
      expect(contract.publicTables['session_overview']!.isView, isTrue);
    });

    test('lists functions by name with conservative json returns', () {
      final contract = loadContractFromString(draft);
      expect(contract.rpcFunctions!.keys.toSet(),
          equals({'get_session_by_code', 'heartbeat'}));
      expect(contract.rpcFunctions!['heartbeat']!.returns, equals('json'));
    });
  });

  group('DbFunction.parse', () {
    test('handles modes, defaults, and nested type parens', () {
      final fn = DbFunction.parse(
        name: 'f',
        argumentSignature:
            'IN p_id uuid, INOUT p_amount numeric(10,2), OUT result text, '
            "p_note text DEFAULT 'n/a'::text",
        returnSignature: 'numeric',
        isSecurityDefiner: false,
        hasSearchPath: false,
      );
      expect(fn.args,
          equals({'p_id': 'uuid', 'p_amount': 'numeric(10,2)', 'p_note': 'text'}));
      expect(fn.optionalArgs, equals(['p_note']));
      expect(fn.argsIncomplete, isFalse);
    });

    test('flags unnamed arguments as incomplete', () {
      final fn = DbFunction.parse(
        name: 'f',
        argumentSignature: 'uuid, text',
        returnSignature: 'void',
        isSecurityDefiner: false,
        hasSearchPath: false,
      );
      expect(fn.args, isEmpty);
      expect(fn.argsIncomplete, isTrue);
    });
  });
}
