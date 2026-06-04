/// Generator CLI: reads a supabase.yaml contract and produces Dart client code.
///
/// Usage:
///   dart run tool/generate.dart --contract docs/contracts/supabase.yaml --output lib/generated
///   dart run tool/generate.dart --contract docs/contracts/supabase.yaml --output lib/generated --with-db
///   dart run tool/generate.dart --contract docs/contracts/supabase.yaml --output lib/generated --check
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

import 'package:supabase_client_gen/src/contract.dart';
import 'package:supabase_client_gen/src/db_schema.dart';
import 'package:supabase_client_gen/src/generator.dart';

Future<void> main(List<String> args) async {
  final checkMode = args.contains('--check');
  final withDb = args.contains('--with-db');
  final contractPath = _arg(args, '--contract');
  final outputDir = _arg(args, '--output');

  if (contractPath == null || outputDir == null) {
    stderr.writeln('Usage: dart run tool/generate.dart --contract <path> --output <dir> [--check] [--with-db]');
    exit(1);
  }

  if (!File(contractPath).existsSync()) {
    stderr.writeln('Error: Contract file not found at $contractPath');
    exit(1);
  }

  final yamlContent = File(contractPath).readAsStringSync();
  final yaml = _yamlToJson(loadYaml(yamlContent)) as Map<String, dynamic>;
  final contract = SupabaseContract.fromYaml(yaml);

  // Optionally snapshot the DB for nullability detection.
  DbSchema? dbSchema;
  if (withDb) {
    try {
      dbSchema = await DbSchema.fetch();
      stdout.writeln(
        '  DB snapshot: ${dbSchema.tables.length} tables, ${dbSchema.enumValues.length} enums',
      );
    } catch (e) {
      stdout.writeln('  DB not available, using contract-only nullability: $e');
    }
  }

  final generator = ClientGenerator(contract, dbSchema: dbSchema);
  final files = generator.generate();

  // Write generated files to a temp dir, format them, then compare.
  final tempDir = Directory.systemTemp.createTempSync('supabase_client_gen_');
  try {
    for (final entry in files.entries) {
      final filePath = '${tempDir.path}/${entry.key}';
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }

    Process.runSync('dart', ['format', tempDir.path], runInShell: true);

    if (checkMode) {
      var dirty = false;
      for (final entry in files.entries) {
        final tempFile = File('${tempDir.path}/${entry.key}');
        final genContent = tempFile.readAsStringSync();
        final diskFile = File('$outputDir/${entry.key}');
        if (!diskFile.existsSync()) {
          stderr.writeln('Missing: ${entry.key}');
          dirty = true;
        } else if (diskFile.readAsStringSync() != genContent) {
          stderr.writeln('Out of date: ${entry.key}');
          dirty = true;
        }
      }
      if (dirty) {
        stderr.writeln('\nGenerated code out of sync. Run the generator without --check to update.');
        exit(1);
      }
      stdout.writeln('OK: Generated code matches contract.');
      exit(0);
    }

    // Not check mode: copy formatted files to output.
    for (final entry in files.entries) {
      final tempFile = File('${tempDir.path}/${entry.key}');
      final destPath = '$outputDir/${entry.key}';
      final destFile = File(destPath);
      destFile.parent.createSync(recursive: true);
      tempFile.copySync(destPath);
      stdout.writeln('  Wrote: ${entry.key}');
    }
  } finally {
    tempDir.deleteSync(recursive: true);
  }
}

String? _arg(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i >= 0 && i + 1 < args.length) return args[i + 1];
  return null;
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
