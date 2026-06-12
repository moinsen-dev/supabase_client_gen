/// Best-practice linter CLI for `supabase.yaml` contracts.
///
/// Usage:
///   dart run supabase_client_gen:doctor --contract supabase.yaml \
///     [--db-url <postgres-url>] [--json] [--strict]
///
/// Contract-only rules (DR0xx) always run; with a database URL the DB rules
/// (DR1xx) run as well — unmanaged RPCs, missing RLS, SECURITY DEFINER
/// hygiene. Exit code: 0 when clean or info-only, 1 on errors (with --strict
/// also on warnings).
library;

import 'dart:convert';
import 'dart:io';

import 'package:supabase_client_gen/src/contract_loader.dart';
import 'package:supabase_client_gen/src/db_schema.dart';
import 'package:supabase_client_gen/src/doctor.dart';
import 'package:supabase_client_gen/src/version.dart';
import 'package:yaml/yaml.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('supabase_client_gen $packageVersion');
    return;
  }

  final contractPath = _arg(args, '--contract');
  final jsonOut = args.contains('--json');
  final strict = args.contains('--strict');
  final withDb = args.contains('--with-db') || _arg(args, '--db-url') != null;
  final dbUrl =
      _arg(args, '--db-url') ?? Platform.environment['SUPABASE_DB_URL'];

  if (contractPath == null) {
    stderr.writeln(
      'Usage: doctor --contract <path> [--db-url <url>] [--json] [--strict]',
    );
    exit(1);
  }

  final file = File(contractPath);
  if (!file.existsSync()) {
    stderr.writeln('Error: Contract file not found at $contractPath');
    exit(1);
  }

  // Doctor lints the raw mapping (more tolerant than the strict loader), so
  // it can examine drafts the loader would reject.
  final dynamic rawYaml;
  try {
    rawYaml = yamlToJson(loadYaml(file.readAsStringSync()));
  } catch (e) {
    stderr.writeln('Error: could not parse YAML in $contractPath:\n  $e');
    exit(1);
  }
  if (rawYaml is! Map<String, dynamic>) {
    stderr.writeln(
      'Error: contract root must be a mapping, got '
      '${rawYaml.runtimeType} in $contractPath',
    );
    exit(1);
  }

  final findings = [...lintContract(rawYaml)];

  if (withDb) {
    if (dbUrl == null || dbUrl.isEmpty) {
      stderr.writeln('Error: DB rules need --db-url (or SUPABASE_DB_URL).');
      exit(1);
    }
    final DbSchema db;
    try {
      db = await DbSchema.fetch(url: dbUrl);
    } catch (e) {
      stderr.writeln('Error: could not introspect the database: $e');
      exit(1);
    }
    findings.addAll(lintAgainstDb(rawYaml, db));
  }

  final errors =
      findings.where((f) => f.severity == DoctorSeverity.error).length;
  final warns = findings.where((f) => f.severity == DoctorSeverity.warn).length;
  final infos = findings.where((f) => f.severity == DoctorSeverity.info).length;

  if (jsonOut) {
    stdout.writeln(const JsonEncoder.withIndent('  ')
        .convert([for (final f in findings) f.toJson()]));
  } else {
    if (findings.isEmpty) {
      stdout.writeln('OK: no findings. The contract looks healthy.');
    } else {
      for (final f in findings) {
        stdout.writeln('${_icon(f.severity)} ${f.code} '
            '[${f.severity.name}] ${f.path}');
        stdout.writeln('    ${f.message}');
        stdout.writeln('    fix: ${f.fix}');
      }
      stdout.writeln();
      stdout.writeln('$errors error(s), $warns warning(s), $infos note(s).');
      if (!withDb) {
        stdout.writeln(
          'Tip: add --db-url to also check the live database (unmanaged '
          'RPCs, RLS, SECURITY DEFINER hygiene).',
        );
      }
    }
  }

  if (errors > 0 || (strict && warns > 0)) exit(1);
}

String _icon(DoctorSeverity s) => switch (s) {
      DoctorSeverity.error => '✗',
      DoctorSeverity.warn => '⚠',
      DoctorSeverity.info => 'ℹ',
    };

String? _arg(List<String> args, String flag) {
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('$flag=')) return args[i].substring(flag.length + 1);
    if (args[i] == flag && i + 1 < args.length) return args[i + 1];
  }
  return null;
}
