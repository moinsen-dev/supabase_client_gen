/// Brownfield import CLI: drafts a `supabase.yaml` contract from an existing
/// backend.
///
/// Usage:
///   dart run supabase_client_gen:init --from-db --db-url <postgres-url> \
///     --output supabase.yaml [--name <project>] [--force]
///   dart run supabase_client_gen:init --from-gen-types supabase.types.ts \
///     --output supabase.yaml [--name <project>] [--force]
///
/// The draft passes the contract loader and the generator (self-tested before
/// writing) and marks every human decision with `# TODO review`.
library;

import 'dart:io';

import 'package:supabase_client_gen/src/contract_init.dart';
import 'package:supabase_client_gen/src/contract_loader.dart';
import 'package:supabase_client_gen/src/db_schema.dart';
import 'package:supabase_client_gen/src/gen_types.dart';
import 'package:supabase_client_gen/src/generator.dart';
import 'package:supabase_client_gen/src/version.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('supabase_client_gen $packageVersion');
    return;
  }

  final fromDb = args.contains('--from-db');
  final genTypesPath = _arg(args, '--from-gen-types');
  final output = _arg(args, '--output') ?? 'supabase.yaml';
  final name = _arg(args, '--name') ?? 'my_project';
  final force = args.contains('--force');
  final dbUrl =
      _arg(args, '--db-url') ?? Platform.environment['SUPABASE_DB_URL'];

  if (fromDb == (genTypesPath != null)) {
    stderr.writeln(
      'Usage: init (--from-db --db-url <url> | --from-gen-types <file.ts>) '
      '[--output <path>] [--name <project>] [--force]\n'
      'Pick exactly one source: --from-db (live introspection) or '
      '--from-gen-types (offline).',
    );
    exit(1);
  }

  if (File(output).existsSync() && !force) {
    stderr.writeln(
      'Error: $output already exists — refusing to overwrite a contract. '
      'Pass --force to replace it.',
    );
    exit(1);
  }

  final now = DateTime.now();
  final date = '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';

  final String draft;
  if (fromDb) {
    if (dbUrl == null || dbUrl.isEmpty) {
      stderr.writeln(
        'Error: --from-db needs --db-url <postgres-url> (or SUPABASE_DB_URL).',
      );
      exit(1);
    }
    final DbSchema db;
    try {
      db = await DbSchema.fetch(url: dbUrl);
    } catch (e) {
      stderr.writeln('Error: could not introspect the database: $e');
      exit(1);
    }
    draft = buildContractFromDb(db, projectName: name, date: date);
    stdout.writeln(
      '  Introspected: ${db.tables.length} table(s), ${db.views.length} '
      'view(s), ${db.enumValues.length} enum(s), ${db.functions.length} '
      'function(s), ${db.storageBuckets.length} bucket(s), '
      '${db.realtimeTables.length} realtime table(s)',
    );
  } else {
    final file = File(genTypesPath!);
    if (!file.existsSync()) {
      stderr.writeln('Error: gen-types file not found at $genTypesPath');
      exit(1);
    }
    final types = GenTypes.parse(file.readAsStringSync());
    draft = buildContractFromGenTypes(types, projectName: name, date: date);
    stdout.writeln(
      '  Parsed: ${types.tableNames.length} table(s), '
      '${types.viewNames.length} view(s), ${types.enumNames.length} enum(s), '
      '${types.functionNames.length} function(s)',
    );
    stdout.writeln(
      '  Note: gen-types is lossy — field types are approximations; storage '
      'and realtime are not recoverable.',
    );
  }

  // Self-test: the draft must survive its own loader and generator before it
  // is allowed to touch the disk. A draft we cannot consume is a bug, not a
  // user problem.
  try {
    final contract = loadContractFromString(draft, sourceName: output);
    ClientGenerator(contract).generate();
  } catch (e) {
    stderr.writeln(
      'Internal error: the generated draft does not pass validation — this '
      'is a bug in supabase_client_gen, please report it.\n  $e',
    );
    exit(1);
  }

  File(output).writeAsStringSync(draft);
  stdout.writeln('  Wrote: $output');
  final todoCount = '# TODO review'.allMatches(draft).length;
  stdout.writeln(
    '  Next: resolve the $todoCount `# TODO review` marker(s), then run '
    'generate --contract $output --output lib/generated',
  );
}

String? _arg(List<String> args, String flag) {
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('$flag=')) return args[i].substring(flag.length + 1);
    if (args[i] == flag && i + 1 < args.length) return args[i + 1];
  }
  return null;
}
