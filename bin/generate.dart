/// Generator CLI: reads a supabase.yaml contract and produces Dart client code.
///
/// Usage:
///   dart run supabase_client_gen:generate --contract <path> --output <dir>
///   dart run supabase_client_gen:generate --contract <path> --output <dir> --check
///   dart run supabase_client_gen:generate --contract <path> --output <dir> --with-db --sync-nullability
library;

import 'dart:io';

import 'package:supabase_client_gen/src/contract.dart';
import 'package:supabase_client_gen/src/contract_loader.dart';
import 'package:supabase_client_gen/src/db_schema.dart';
import 'package:supabase_client_gen/src/nullability_sync.dart';
import 'package:supabase_client_gen/src/render.dart';
import 'package:supabase_client_gen/src/version.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('supabase_client_gen $packageVersion');
    return;
  }
  final checkMode = args.contains('--check');
  final withDb = args.contains('--with-db');
  final syncNullability = args.contains('--sync-nullability');
  final contractPath = _arg(args, '--contract');
  final outputDir = _arg(args, '--output');
  final dbUrl =
      _arg(args, '--db-url') ?? Platform.environment['SUPABASE_DB_URL'];

  if (contractPath == null || outputDir == null) {
    stderr.writeln(
      'Usage: generate --contract <path> --output <dir> [--check] '
      '[--with-db] [--sync-nullability] [--db-url <url>]',
    );
    exit(1);
  }

  if (!File(contractPath).existsSync()) {
    stderr.writeln('Error: Contract file not found at $contractPath');
    exit(1);
  }

  // Optionally materialise live-DB nullability into the contract before
  // generating, so generated output stays deterministic but DB-accurate.
  if (syncNullability) {
    if (!withDb) {
      stderr.writeln('Error: --sync-nullability requires --with-db.');
      exit(1);
    }
    try {
      final dbSchema = await DbSchema.fetch(url: dbUrl);
      final changed = syncNullabilityIntoContract(contractPath, dbSchema);
      stdout.writeln(
        changed == 0
            ? '  Nullability already in sync with DB.'
            : '  Synced nullability for $changed field(s) into $contractPath',
      );
    } catch (e) {
      stderr.writeln('Error: --sync-nullability failed: $e');
      exit(1);
    }
  } else if (withDb) {
    stdout.writeln(
      '  Note: --with-db no longer affects generation (output is contract-only '
      'and deterministic). Use --sync-nullability to fold DB nullability into '
      'the contract, or `validate --with-db` to detect drift.',
    );
  }

  final SupabaseContract contract;
  try {
    contract = loadContract(contractPath);
  } on ContractError catch (e) {
    stderr.writeln('Contract error: $e');
    exit(1);
  }

  final Map<String, String> files;
  try {
    files = renderFormatted(contract);
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }

  if (checkMode) {
    final outcome = checkAgainst(files, outputDir);
    if (!outcome.isClean) {
      for (final f in outcome.missing) {
        stderr.writeln('Missing: $f');
      }
      for (final f in outcome.outOfDate) {
        stderr.writeln('Out of date: $f');
      }
      stderr.writeln(
        '\nGenerated code out of sync. Run the generator without --check to update.',
      );
      exit(1);
    }
    stdout.writeln('OK: Generated code matches contract.');
    exit(0);
  }

  writeOutput(files, outputDir);
  for (final key in files.keys) {
    stdout.writeln('  Wrote: $key');
  }
}

String? _arg(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i >= 0 && i + 1 < args.length) return args[i + 1];
  return null;
}
