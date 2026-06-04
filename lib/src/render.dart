/// Shared rendering pipeline used by both the `generate` and `validate` CLIs
/// and by the golden tests.
///
/// One place that knows how to turn a [SupabaseContract] into the final,
/// `dart format`-ed file map, plus how to compare/write that map. Keeping this
/// single-sourced is what makes the generator's output deterministic and the
/// `--check` / `validate --mode=types` paths provably identical.
library;

import 'dart:io';

import 'contract.dart';
import 'generator.dart';

/// Generates the client code for [contract] and runs `dart format` over it.
///
/// Returns a map of relative-path → formatted source. Throws [StateError] if
/// `dart format` is unavailable or exits non-zero — a silent format failure
/// would corrupt every downstream comparison, so we fail loudly instead.
Map<String, String> renderFormatted(SupabaseContract contract) {
  final files = ClientGenerator(contract).generate();
  final tempDir = Directory.systemTemp.createTempSync('supabase_client_gen_');
  try {
    for (final entry in files.entries) {
      final file = File('${tempDir.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }

    // Pin the language version so formatting style never depends on an ambient
    // pubspec or which Dart SDK happens to run the generator — the output must
    // be byte-identical across machines and projects.
    final result = Process.runSync(
      'dart',
      ['format', '--language-version=latest', tempDir.path],
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw StateError(
        'dart format failed (exit ${result.exitCode}). '
        'Generated code cannot be trusted.\n${result.stderr}',
      );
    }

    final formatted = <String, String>{};
    for (final entry in files.entries) {
      formatted[entry.key] =
          File('${tempDir.path}/${entry.key}').readAsStringSync();
    }
    return formatted;
  } finally {
    tempDir.deleteSync(recursive: true);
  }
}

/// Result of comparing freshly rendered files against an output directory.
class CheckOutcome {
  /// Files the generator would write that are missing on disk.
  final List<String> missing;

  /// Files whose on-disk content differs from freshly rendered content.
  final List<String> outOfDate;

  const CheckOutcome({required this.missing, required this.outOfDate});

  bool get isClean => missing.isEmpty && outOfDate.isEmpty;
}

/// Compares [rendered] against the files in [outputDir].
CheckOutcome checkAgainst(Map<String, String> rendered, String outputDir) {
  final missing = <String>[];
  final outOfDate = <String>[];
  for (final entry in rendered.entries) {
    final diskFile = File('$outputDir/${entry.key}');
    if (!diskFile.existsSync()) {
      missing.add(entry.key);
    } else if (diskFile.readAsStringSync() != entry.value) {
      outOfDate.add(entry.key);
    }
  }
  return CheckOutcome(missing: missing, outOfDate: outOfDate);
}

/// Writes [rendered] into [outputDir], creating parent directories as needed.
void writeOutput(Map<String, String> rendered, String outputDir) {
  for (final entry in rendered.entries) {
    final dest = File('$outputDir/${entry.key}');
    dest.parent.createSync(recursive: true);
    dest.writeAsStringSync(entry.value);
  }
}
