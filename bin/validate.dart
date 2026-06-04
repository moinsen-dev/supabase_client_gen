/// Validation CLI: checks DB↔Contract↔Generated-Code alignment.
///
/// Usage:
///   dart run tool/validate.dart --contract <path> --output <dir> --mode=db
///   dart run tool/validate.dart --contract <path> --output <dir> --mode=types
///   dart run tool/validate.dart --contract <path> --output <dir> --ts <path> --migrations <dir> --mode=all
///   dart run tool/validate.dart ... --with-db
library;

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'package:supabase_client_gen/src/contract.dart';
import 'package:supabase_client_gen/src/db_schema.dart';
import 'package:supabase_client_gen/src/diff.dart';
import 'package:supabase_client_gen/src/gen_types.dart';
import 'package:supabase_client_gen/src/generator.dart';

Future<void> main(List<String> args) async {
  final mode = _arg(args, '--mode') ?? 'all';
  final jsonOut = args.contains('--json');
  final withDb = args.contains('--with-db');
  final contractPath = _arg(args, '--contract');
  final outputDir = _arg(args, '--output');
  final tsPath = _arg(args, '--ts');
  final migrationsDir = _arg(args, '--migrations');

  if (contractPath == null || outputDir == null) {
    stderr.writeln('Usage: dart run tool/validate.dart --contract <path> --output <dir> [--ts <path>] [--migrations <dir>] [--mode=<mode>] [--with-db] [--json]');
    exit(1);
  }

  final yaml =
      _yamlToJson(loadYaml(File(contractPath).readAsStringSync()))
          as Map<String, dynamic>;
  final contract = SupabaseContract.fromYaml(yaml);

  var hasErrors = false;
  DbSchema? dbSchema;

  if (withDb || mode == 'db' || mode == 'all') {
    try {
      dbSchema = await DbSchema.fetch();
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
  if (jsonOut) {
    stdout.writeln(jsonEncode(diff.toJson()));
    return diff.hasErrors;
  } else {
    stdout.writeln(diff.format());
    return !diff.isClean;
  }
}

bool _checkTypes(
  SupabaseContract contract,
  String outputDir,
  bool jsonOut,
  DbSchema? dbSchema,
) {
  final generator = ClientGenerator(contract, dbSchema: dbSchema);
  final files = generator.generate();

  final tempDir = Directory.systemTemp.createTempSync('supabase_client_gen_validate_');
  var dirty = false;
  try {
    for (final entry in files.entries) {
      final filePath = '${tempDir.path}/${entry.key}';
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    Process.runSync('dart', ['format', tempDir.path], runInShell: true);

    for (final entry in files.entries) {
      final tempFile = File('${tempDir.path}/${entry.key}');
      final genContent = tempFile.readAsStringSync();
      final file = File('$outputDir/${entry.key}');
      if (!file.existsSync() || file.readAsStringSync() != genContent) {
        if (!jsonOut) stdout.writeln('  ✗ ${entry.key}: out of date');
        dirty = true;
      }
    }
  } finally {
    tempDir.deleteSync(recursive: true);
  }
  if (!dirty && !jsonOut)
    stdout.writeln('  OK: Generated code matches contract.');
  return dirty;
}

bool _checkGenTypes(SupabaseContract contract, String tsPath, bool jsonOut) {
  if (!File(tsPath).existsSync()) {
    if (!jsonOut)
      stdout.writeln(
        '  ⚠ supabase.types.ts not found. Run: supabase gen types --local',
      );
    return false;
  }

  final ts = File(tsPath).readAsStringSync();
  final genTypes = GenTypes.parse(ts);
  final contractTables = contract.publicTables.keys.toSet();
  var issues = 0;

  for (final t in genTypes.tableNames.difference(contractTables)) {
    if (!jsonOut)
      stdout.writeln('  ✗ Table public.$t in supabase.types.ts but not in contract');
    issues++;
  }
  for (final t in contractTables.difference(genTypes.tableNames)) {
    if (!jsonOut)
      stdout.writeln('  ✗ Table public.$t in contract but not in supabase.types.ts');
    issues++;
  }

  for (final t in contractTables.intersection(genTypes.tableNames)) {
    final contractCols = contract.publicTables[t]!.fields.keys.toSet();
    final genCols = genTypes.tableColumns[t] ?? {};
    for (final c in genCols.difference(contractCols)) {
      if (!jsonOut)
        stdout.writeln('  ✗ Column $t.$c in supabase.types.ts but not in contract');
      issues++;
    }
    for (final c in contractCols.difference(genCols)) {
      if (!jsonOut)
        stdout.writeln('  ✗ Column $t.$c in contract but not in supabase.types.ts');
      issues++;
    }
  }

  final contractEnums = contract.allEnumValues.keys.toSet();
  for (final e in genTypes.enumNames.difference(contractEnums)) {
    if (!jsonOut)
      stdout.writeln('  ℹ Enum $e in supabase.types.ts but not in contract');
  }
  for (final e in contractEnums.difference(genTypes.enumNames)) {
    if (!jsonOut)
      stdout.writeln('  ✗ Enum $e in contract but not in supabase.types.ts');
    issues++;
  }

  if (issues == 0 && !jsonOut)
    stdout.writeln('  OK: Contract matches supabase.types.ts.');
  return issues > 0;
}

bool _checkMigrations(SupabaseContract contract, String migrationsDir, bool jsonOut) {
  final dir = Directory(migrationsDir);
  if (!dir.existsSync()) {
    if (!jsonOut) stdout.writeln('  ⚠ Migrations directory not found.');
    return false;
  }
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.sql')).toList();
  files.sort((a, b) => b.path.compareTo(a.path));
  final latest = files.isNotEmpty ? files.first.path.split('/').last : null;
  if (latest == null) {
    if (!jsonOut) stdout.writeln('  ⚠ No migration files found.');
    return false;
  }
  final migrationDate = latest.substring(0, 8);
  final contractDate = contract.date.replaceAll('-', '');
  final newer = migrationDate.compareTo(contractDate) > 0;
  if (newer) {
    if (!jsonOut)
      stdout.writeln('  ⚠ Migrations exist after contract date — contract may be stale.');
  } else {
    if (!jsonOut) stdout.writeln('  OK: No migrations newer than contract.');
  }
  return newer;
}

dynamic _yamlToJson(dynamic node) {
  if (node is YamlMap) {
    return Map<String, dynamic>.fromEntries(
      node.entries.map((e) => MapEntry(e.key.toString(), _yamlToJson(e.value))),
    );
  }
  if (node is YamlList) return node.map(_yamlToJson).toList();
  return node;
}
