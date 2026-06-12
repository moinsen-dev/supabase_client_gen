/// Rule-level tests for the `doctor` linter: every rule has a fixture that
/// triggers it and a healthy counterpart that must stay silent.
library;

import 'package:supabase_client_gen/src/contract_loader.dart';
import 'package:supabase_client_gen/src/db_schema.dart';
import 'package:supabase_client_gen/src/doctor.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

Map<String, dynamic> _raw(String yaml) =>
    yamlToJson(loadYaml(yaml)) as Map<String, dynamic>;

List<String> _codes(List<DoctorFinding> findings) =>
    findings.map((f) => f.code).toList();

/// A contract that violates nothing — the negative fixture for every rule.
const _healthy = '''
data_model:
  public:
    things:
      ownership: workspace
      primary_key: id
      fields:
        id: uuid
        category: thing_category
      enum_values:
        thing_category: [device, other]
      client_access:
        select: authenticated
        insert: edge_function_only
        update: edge_function_only
        delete: edge_function_only
    things_overview:
      kind: view
      ownership: workspace
      primary_key: id
      fields:
        id: uuid
      client_access:
        select: authenticated
edge_functions:
  runtime: deno
  resolve_thing:
    method: POST
    description: Resolves a thing.
rpc_functions:
  add_note:
    description: Adds a note.
    args: { p_id: uuid }
    returns: uuid
storage:
  buckets:
    files:
      public: false
realtime:
  publication:
    allowed_tables:
      - public.things
  events:
    thing_changed:
      source: public.things
      audience: authenticated
''';

void main() {
  group('contract-only rules', () {
    test('healthy contract produces no findings', () {
      expect(lintContract(_raw(_healthy)), isEmpty);
    });

    test('DR001: table without primary_key', () {
      final findings = lintContract(_raw('''
data_model:
  public:
    things:
      ownership: global
      fields: { id: uuid }
      client_access: { select: authenticated }
'''));
      expect(_codes(findings), contains('DR001'));
      final f = findings.firstWhere((f) => f.code == 'DR001');
      expect(f.severity, DoctorSeverity.error);
      expect(f.path, 'data_model.public.things.primary_key');
    });

    test('DR002: client_access missing entirely', () {
      final findings = lintContract(_raw('''
data_model:
  public:
    things:
      ownership: global
      primary_key: id
      fields: { id: uuid }
'''));
      expect(_codes(findings), contains('DR002'));
      expect(findings.firstWhere((f) => f.code == 'DR002').severity,
          DoctorSeverity.warn);
    });

    test('DR003: mutation access declared on a view', () {
      final findings = lintContract(_raw('''
data_model:
  public:
    overview:
      kind: view
      ownership: global
      primary_key: id
      fields: { id: uuid }
      client_access:
        select: authenticated
        insert: authenticated
        delete: authenticated
'''));
      final f = findings.firstWhere((f) => f.code == 'DR003');
      expect(f.severity, DoctorSeverity.warn);
      expect(f.message, contains('insert/delete'));
    });

    test('DR004: enum declared but unused as a field type', () {
      final findings = lintContract(_raw('''
data_model:
  public:
    things:
      ownership: global
      primary_key: id
      fields: { id: uuid, status: text }
      enum_values:
        thing_status: [open, closed]
      client_access: { select: authenticated }
'''));
      final f = findings.firstWhere((f) => f.code == 'DR004');
      expect(f.path, 'data_model.public.things.enum_values.thing_status');
    });

    test('DR005/DR006: edge and rpc functions without description', () {
      final findings = lintContract(_raw('''
data_model: { public: {} }
edge_functions:
  runtime: deno
  resolve:
    method: POST
rpc_functions:
  tally:
    args: { p_id: uuid }
    returns: json
'''));
      expect(_codes(findings), containsAll(['DR005', 'DR006']));
      expect(
          findings
              .where((f) => f.severity == DoctorSeverity.info)
              .map((f) => f.code),
          containsAll(['DR005', 'DR006']));
    });

    test('DR007: public storage bucket', () {
      final findings = lintContract(_raw('''
data_model: { public: {} }
storage:
  buckets:
    avatars:
      public: true
'''));
      final f = findings.firstWhere((f) => f.code == 'DR007');
      expect(f.severity, DoctorSeverity.warn);
      expect(f.path, 'storage.buckets.avatars');
    });

    test('DR008: event sources a table missing from the publication', () {
      final findings = lintContract(_raw('''
data_model: { public: {} }
realtime:
  publication:
    allowed_tables:
      - public.things
  events:
    song_added:
      source: public.songs
      audience: session
'''));
      final f = findings.firstWhere((f) => f.code == 'DR008');
      expect(f.severity, DoctorSeverity.error);
      expect(f.path, 'realtime.events.song_added');
    });

    test('DR009: primary_key column not in fields (composite too)', () {
      final findings = lintContract(_raw('''
data_model:
  public:
    players:
      ownership: global
      primary_key: [session_id, user_id]
      fields: { session_id: uuid }
      client_access: { select: authenticated }
'''));
      final f = findings.firstWhere((f) => f.code == 'DR009');
      expect(f.severity, DoctorSeverity.error);
      expect(f.message, contains("'user_id'"));
    });
  });

  group('DB rules', () {
    final raw = _raw('''
data_model:
  public:
    things:
      ownership: global
      primary_key: id
      fields: { id: uuid }
      client_access: { select: authenticated }
rpc_functions:
  declared_missing_in_db:
    description: Exists only in the contract.
    returns: json
''');

    final db = DbSchema(
      tables: {
        'things': DbTable(name: 'things', columns: const []),
        'server_only': DbTable(name: 'server_only', columns: const []),
      },
      enumValues: const {},
      functions: {
        'unmanaged_fn': DbFunction.parse(
          name: 'unmanaged_fn',
          argumentSignature: '',
          returnSignature: 'json',
          isSecurityDefiner: true,
          hasSearchPath: false,
        ),
      },
      rlsEnabled: const {'things': false, 'server_only': true},
      securityDefinerViews: const {'leaky_view'},
    );

    final findings = lintAgainstDb(raw, db);

    test('DR101: unmanaged DB function (the MercyNight killer)', () {
      final f = findings.firstWhere((f) => f.code == 'DR101');
      expect(f.severity, DoctorSeverity.warn);
      expect(f.message, contains('unmanaged_fn'));
    });

    test('DR102: contract RPC missing in DB is an error', () {
      final f = findings.firstWhere((f) => f.code == 'DR102');
      expect(f.severity, DoctorSeverity.error);
      expect(f.path, 'rpc_functions.declared_missing_in_db');
    });

    test('DR103: SECURITY DEFINER without search_path', () {
      final f = findings.firstWhere((f) => f.code == 'DR103');
      expect(f.severity, DoctorSeverity.warn);
      expect(f.path, 'db.functions.unmanaged_fn');
    });

    test('DR104: view without security_invoker', () {
      final f = findings.firstWhere((f) => f.code == 'DR104');
      expect(f.severity, DoctorSeverity.warn);
      expect(f.path, 'db.views.leaky_view');
    });

    test('DR105: DB table not in contract is informational', () {
      final f = findings.firstWhere((f) => f.code == 'DR105');
      expect(f.severity, DoctorSeverity.info);
      expect(f.message, contains('server_only'));
      expect(f.fix, contains('init --from-db'));
    });

    test('DR106: RLS disabled on a contract table is an error', () {
      final f = findings.firstWhere((f) => f.code == 'DR106');
      expect(f.severity, DoctorSeverity.error);
      expect(f.path, 'data_model.public.things');
    });

    test('clean DB against matching contract produces no findings', () {
      final cleanDb = DbSchema(
        tables: {'things': DbTable(name: 'things', columns: const [])},
        enumValues: const {},
        functions: {
          'declared_missing_in_db': DbFunction.parse(
            name: 'declared_missing_in_db',
            argumentSignature: '',
            returnSignature: 'json',
            isSecurityDefiner: true,
            hasSearchPath: true,
          ),
        },
        rlsEnabled: const {'things': true},
      );
      expect(lintAgainstDb(raw, cleanDb), isEmpty);
    });
  });
}
