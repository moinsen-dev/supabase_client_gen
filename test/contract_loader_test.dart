import 'dart:io';

import 'package:supabase_client_gen/src/contract_loader.dart';
import 'package:test/test.dart';

/// Writes [yaml] to a temp file and returns its path.
String _tmp(String yaml) {
  final f = File(
    '${Directory.systemTemp.createTempSync('sclg_test_').path}/c.yaml',
  )..writeAsStringSync(yaml);
  return f.path;
}

const _validHeader = '''
contract:
  name: t
  version: "0.1.0"
  date: "2026-06-04"
project:
  remote:
    name: t
    ref: ref
auth:
  provider: supabase
  planned_sign_in_methods: [email]
data_model:
  public:
    things:
      ownership: workspace
      primary_key: id
      fields:
        id: uuid
''';

void main() {
  group('loadContract friendly validation', () {
    test('loads a valid contract', () {
      final c = loadContract(_tmp(_validHeader));
      expect(c.contract.name, 't');
      expect(c.publicTables.keys, contains('things'));
    });

    test('missing file', () {
      expect(
        () => loadContract('/no/such/contract.yaml'),
        throwsA(isA<ContractError>()
            .having((e) => e.message, 'message', contains('not found'))),
      );
    });

    test('rejects the flat project form with a helpful message', () {
      final yaml = _validHeader.replaceFirst(
        'project:\n  remote:\n    name: t\n    ref: ref',
        'project:\n  name: t\n  organization: o\n  region: eu',
      );
      expect(
        () => loadContract(_tmp(yaml)),
        throwsA(isA<ContractError>()
            .having((e) => e.message, 'message', contains('project.remote'))),
      );
    });

    test('reports the offending table path for a missing primary_key', () {
      final yaml = _validHeader.replaceFirst('      primary_key: id\n', '');
      expect(
        () => loadContract(_tmp(yaml)),
        throwsA(isA<ContractError>().having((e) => e.message, 'message',
            contains('data_model.public.things.primary_key'))),
      );
    });

    test('reports missing required top-level section', () {
      final yaml = _validHeader.replaceFirst(
          'auth:\n  provider: supabase\n  planned_sign_in_methods: [email]\n',
          '');
      expect(
        () => loadContract(_tmp(yaml)),
        throwsA(isA<ContractError>()
            .having((e) => e.message, 'message', contains('auth'))),
      );
    });

    test('parses rpc_functions with args, optional_args and returns', () {
      final yaml = '$_validHeader'
          'rpc_functions:\n'
          '  do_thing:\n'
          '    args: { p_id: uuid, p_note: text }\n'
          '    optional_args: [p_note]\n'
          '    returns: row:things\n';
      final c = loadContract(_tmp(yaml));
      final fn = c.rpcFunctions!['do_thing']!;
      expect(fn.args.keys.toList(), ['p_id', 'p_note']);
      expect(fn.optionalArgs, ['p_note']);
      expect(fn.returns, 'row:things');
    });

    test('reports the offending path for an invalid rpc returns', () {
      final yaml = '$_validHeader'
          'rpc_functions:\n'
          '  do_thing:\n'
          '    returns: blob\n';
      expect(
        () => loadContract(_tmp(yaml)),
        throwsA(isA<ContractError>().having((e) => e.message, 'message',
            contains('rpc_functions.do_thing.returns'))),
      );
    });

    test('rejects a row: return referencing an undeclared table', () {
      final yaml = '$_validHeader'
          'rpc_functions:\n'
          '  do_thing:\n'
          '    returns: row:nonexistent\n';
      expect(
        () => loadContract(_tmp(yaml)),
        throwsA(isA<ContractError>().having((e) => e.message, 'message',
            contains("references table 'nonexistent'"))),
      );
    });

    test('rejects optional_args that are not a subset of args', () {
      final yaml = '$_validHeader'
          'rpc_functions:\n'
          '  do_thing:\n'
          '    args: { p_id: uuid }\n'
          '    optional_args: [p_ghost]\n'
          '    returns: void\n';
      expect(
        () => loadContract(_tmp(yaml)),
        throwsA(isA<ContractError>().having((e) => e.message, 'message',
            contains('rpc_functions.do_thing.optional_args'))),
      );
    });

    test('reports a missing rpc returns with its path', () {
      final yaml = '$_validHeader'
          'rpc_functions:\n'
          '  do_thing:\n'
          '    args: { p_id: uuid }\n';
      expect(
        () => loadContract(_tmp(yaml)),
        throwsA(isA<ContractError>().having((e) => e.message, 'message',
            contains('rpc_functions.do_thing.returns is required'))),
      );
    });

    test('parses the composite primary_key list form', () {
      final yaml = _validHeader.replaceFirst(
          '      primary_key: id\n', '      primary_key: [id, name]\n');
      final c = loadContract(_tmp(yaml));
      expect(c.publicTables['things']!.primaryKey, ['id', 'name']);
    });

    test('scalar primary_key parses as a single-element list', () {
      final c = loadContract(_tmp(_validHeader));
      expect(c.publicTables['things']!.primaryKey, ['id']);
    });

    test('rejects an empty primary_key list with its path', () {
      final yaml = _validHeader.replaceFirst(
          '      primary_key: id\n', '      primary_key: []\n');
      expect(
        () => loadContract(_tmp(yaml)),
        throwsA(isA<ContractError>().having((e) => e.message, 'message',
            contains('data_model.public.things.primary_key'))),
      );
    });

    test('parses kind: view and defaults kind to table', () {
      final yaml = _validHeader.replaceFirst('      ownership: workspace\n',
          '      ownership: workspace\n      kind: view\n');
      final c = loadContract(_tmp(yaml));
      expect(c.publicTables['things']!.isView, isTrue);
      expect(loadContract(_tmp(_validHeader)).publicTables['things']!.isView,
          isFalse);
    });

    test('rejects an unknown kind with its path', () {
      final yaml = _validHeader.replaceFirst('      ownership: workspace\n',
          '      ownership: workspace\n      kind: materialized\n');
      expect(
        () => loadContract(_tmp(yaml)),
        throwsA(isA<ContractError>().having((e) => e.message, 'message',
            contains('data_model.public.things.kind'))),
      );
    });

    test('tolerates a scalar runtime key under edge_functions', () {
      final yaml = '$_validHeader'
          'edge_functions:\n'
          '  runtime: deno\n'
          '  do_thing:\n'
          '    method: POST\n';
      final c = loadContract(_tmp(yaml));
      expect(c.edgeFunctions!.keys, contains('do_thing'));
      expect(c.edgeFunctions!.keys, isNot(contains('runtime')));
    });
  });
}
