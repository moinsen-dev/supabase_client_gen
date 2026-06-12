/// Validation CLI: checks DB↔Contract↔Generated-Code alignment.
///
/// Usage:
///   dart run supabase_client_gen:validate --contract <path> --output <dir> --mode=db
///   dart run supabase_client_gen:validate --contract <path> --output <dir> --ts <path> --migrations <dir> --mode=all
library;

import 'dart:io';
import 'package:supabase_client_gen/src/contract.dart';
import 'package:supabase_client_gen/src/contract_loader.dart';
import 'package:supabase_client_gen/src/db_schema.dart';
import 'package:supabase_client_gen/src/diff.dart';
import 'package:supabase_client_gen/src/gen_types.dart';
import 'package:supabase_client_gen/src/render.dart';

Future<void> main(List<String> args) async {
  final mode = _arg(args, '--mode') ?? 'all';
  final jsonOut = args.contains('--json');
  final withDb = args.contains('--with-db');
  final contractPath = _arg(args, '--contract');
  final outputDir = _arg(args, '--output');
  final tsPath = _arg(args, '--ts');
  final migrationsDir = _arg(args, '--migrations');
  final dbUrl =
      _arg(args, '--db-url') ?? Platform.environment['SUPABASE_DB_URL'];

  if (contractPath == null || outputDir == null) {
    stderr.writeln(
        'Usage: validate --contract <path> --output <dir> [--ts <path>] [--migrations <dir>] [--mode=<mode>] [--with-db] [--db-url <url>] [--json]');
    exit(1);
  }

  final SupabaseContract contract;
  try {
    contract = loadContract(contractPath);
  } on ContractError catch (e) {
    stderr.writeln('Contract error: $e');
    exit(1);
  }

  var hasErrors = false;
  DbSchema? dbSchema;

  if (withDb || mode == 'db' || mode == 'all') {
    try {
      dbSchema = await DbSchema.fetch(url: dbUrl);
    } catch (e) {
      if (!jsonOut) stderr.writeln('DB unavailable: $e');
      if (mode == 'db') exit(1);
    }
  }

  if (dbSchema != null && (mode == 'db' || mode == 'all')) {
    if (!jsonOut) stdout.writeln('=== DB Schema vs Contract ===');
    hasErrors |= _checkDb(contract, dbSchema, jsonOut);
  }

  if (mode == 'types' || mode == 'all') {
    if (!jsonOut) stdout.writeln('=== Generated Code vs Contract ===');
    hasErrors |= _checkTypes(contract, outputDir, jsonOut, dbSchema);
  }

  if (tsPath != null && (mode == 'ts' || mode == 'all')) {
    if (!jsonOut) stdout.writeln('=== Contract vs supabase.types.ts ===');
    hasErrors |= _checkGenTypes(contract, tsPath, jsonOut);
  }

  if (migrationsDir != null && (mode == 'migrations' || mode == 'all')) {
    if (!jsonOut) stdout.writeln('=== Migration Freshness ===');
    hasErrors |= _checkMigrations(contract, migrationsDir, jsonOut);
  }

  if (hasErrors) exit(1);
  if (!jsonOut) stdout.writeln('All checks passed.');
}

String? _arg(List<String> args, String flag) {
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('$flag=')) return args[i].substring(flag.length + 1);
    if (args[i] == flag && i + 1 < args.length) return args[i + 1];
  }
  return null;
}

bool _checkDb(SupabaseContract contract, DbSchema db, bool jsonOut) {
  final diff = diffSchema(db, contract);
  // Only error/warning severity fails the check; info-level notes never block.
  if (jsonOut) {
    stdout.writeln(
      '{"errors": ${diff.hasBlocking}, "notes": ${diff.entries.length - diff.blocking.length}}',
    );
  } else {
    stdout.writeln(diff.format());
  }
  return diff.hasBlocking;
}

bool _checkTypes(SupabaseContract contract, String outputDir, bool jsonOut,
    DbSchema? dbSchema) {
  final Map<String, String> files;
  try {
    files = renderFormatted(contract);
  } on StateError catch (e) {
    if (!jsonOut) stdout.writeln('  ✗ ${e.message}');
    return true;
  }
  final outcome = checkAgainst(files, outputDir);
  if (!jsonOut) {
    for (final f in outcome.missing) {
      stdout.writeln('  ✗ $f: missing');
    }
    for (final f in outcome.outOfDate) {
      stdout.writeln('  ✗ $f: out of date');
    }
    if (outcome.isClean) {
      stdout.writeln('  OK: Generated code matches contract.');
    }
  }
  return !outcome.isClean;
}

bool _checkGenTypes(SupabaseContract contract, String tsPath, bool jsonOut) {
  if (!File(tsPath).existsSync()) {
    if (!jsonOut) {
      stdout.writeln(
          '  ⚠ supabase.types.ts not found. Run: supabase gen types --local');
    }
    return false;
  }

  final ts = File(tsPath).readAsStringSync();
  final genTypes = GenTypes.parse(ts);
  // Contract entries split by kind: tables live in the gen-types Tables
  // scope, views in the Views scope.
  final contractTables = contract.publicTables.entries
      .where((e) => !e.value.isView)
      .map((e) => e.key)
      .toSet();
  final contractViews = contract.publicTables.entries
      .where((e) => e.value.isView)
      .map((e) => e.key)
      .toSet();
  var issues = 0;

  for (final t in genTypes.tableNames.difference(contractTables)) {
    if (!jsonOut) {
      stdout.writeln(
          '  ✗ Table public.$t in supabase.types.ts but not in contract');
    }
    issues++;
  }
  for (final t in contractTables.difference(genTypes.tableNames)) {
    if (!jsonOut) {
      stdout.writeln(
          '  ✗ Table public.$t in contract but not in supabase.types.ts');
    }
    issues++;
  }

  // Views declared in the contract must exist as views in the database.
  // (Column-level comparison is not possible: gen-types view rows are not
  // parsed.) A view missing in the DB is blocking drift.
  for (final v in contractViews.difference(genTypes.viewNames)) {
    if (!jsonOut) {
      stdout.writeln(
          '  ✗ View public.$v in contract but not in supabase.types.ts');
    }
    issues++;
  }
  for (final v in genTypes.viewNames.difference(contractViews)) {
    if (!jsonOut) {
      stdout.writeln('  ℹ View $v in supabase.types.ts but not in contract');
    }
  }

  for (final t in contractTables.intersection(genTypes.tableNames)) {
    final contractCols = contract.publicTables[t]!.fields.keys.toSet();
    final genCols = genTypes.tableColumns[t] ?? {};
    for (final c in genCols.difference(contractCols)) {
      if (!jsonOut) {
        stdout.writeln(
            '  ✗ Column $t.$c in supabase.types.ts but not in contract');
      }
      issues++;
    }
    for (final c in contractCols.difference(genCols)) {
      if (!jsonOut) {
        stdout.writeln(
            '  ✗ Column $t.$c in contract but not in supabase.types.ts');
      }
      issues++;
    }
  }

  // Collect enum values from all tables
  final contractEnums = <String>{};
  for (final table in contract.publicTables.values) {
    if (table.enumValues != null) contractEnums.addAll(table.enumValues!.keys);
  }
  for (final e in genTypes.enumNames.difference(contractEnums)) {
    if (!jsonOut) {
      stdout.writeln('  ℹ Enum $e in supabase.types.ts but not in contract');
    }
  }
  for (final e in contractEnums.difference(genTypes.enumNames)) {
    if (!jsonOut) {
      stdout.writeln('  ✗ Enum $e in contract but not in supabase.types.ts');
    }
    issues++;
  }

  // RPC functions declared in the contract must exist in the database
  // (= appear in the gen-types Functions scope). Missing = blocking drift.
  final contractRpc = contract.rpcFunctions?.keys.toSet() ?? <String>{};
  for (final f in contractRpc.difference(genTypes.functionNames)) {
    if (!jsonOut) {
      stdout.writeln(
          '  ✗ RPC function $f in contract but not in supabase.types.ts');
    }
    issues++;
  }
  for (final f in genTypes.functionNames.difference(contractRpc)) {
    if (!jsonOut) {
      stdout
          .writeln('  ℹ Function $f in supabase.types.ts but not in contract');
    }
  }

  if (issues == 0 && !jsonOut) {
    stdout.writeln('  OK: Contract matches supabase.types.ts.');
  }
  return issues > 0;
}

bool _checkMigrations(
    SupabaseContract contract, String migrationsDir, bool jsonOut) {
  final dir = Directory(migrationsDir);
  if (!dir.existsSync()) {
    if (!jsonOut) stdout.writeln('  ⚠ Migrations directory not found.');
    return false;
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList();
  files.sort((a, b) => b.path.compareTo(a.path));
  final latest = files.isNotEmpty ? files.first.path.split('/').last : null;
  if (latest == null) {
    if (!jsonOut) stdout.writeln('  ⚠ No migration files found.');
    return false;
  }
  final migrationDate = latest.substring(0, 8);
  final contractDate = contract.contract.date.replaceAll('-', '');
  final newer = migrationDate.compareTo(contractDate) > 0;
  if (newer) {
    if (!jsonOut) {
      stdout.writeln(
          '  ⚠ Migrations exist after contract date — contract may be stale.');
    }
  } else {
    if (!jsonOut) stdout.writeln('  OK: No migrations newer than contract.');
  }
  return newer;
}
