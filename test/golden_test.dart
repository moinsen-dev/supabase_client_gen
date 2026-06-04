/// Golden/snapshot tests: the executable definition of "correct output".
///
/// Each fixture contract is rendered (generated + `dart format`-ed) and compared
/// byte-for-byte against committed goldens under `test/goldens/<fixture>/`.
///
/// To intentionally update goldens after a reviewed generator change:
///   UPDATE_GOLDENS=1 dart test test/golden_test.dart
/// then review the git diff before committing.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:supabase_client_gen/src/contract_loader.dart';
import 'package:supabase_client_gen/src/render.dart';
import 'package:test/test.dart';

const _fixtures = {
  'helpdesk': 'test/fixtures/helpdesk.supabase.yaml',
  'edge_cases': 'test/fixtures/edge_cases.supabase.yaml',
};

void main() {
  final update = Platform.environment['UPDATE_GOLDENS'] == '1';

  group('golden', () {
    for (final entry in _fixtures.entries) {
      final name = entry.key;
      final contractPath = entry.value;
      final goldenDir = 'test/goldens/$name';

      test(name, () {
        final contract = loadContract(contractPath);
        final rendered = renderFormatted(contract);

        if (update) {
          final dir = Directory(goldenDir);
          if (dir.existsSync()) dir.deleteSync(recursive: true);
          writeOutput(rendered, goldenDir);
          printOnFailure('Wrote ${rendered.length} goldens to $goldenDir');
          return;
        }

        // Every rendered file must match its golden.
        for (final f in rendered.entries) {
          final goldenFile = File(p.join(goldenDir, f.key));
          expect(
            goldenFile.existsSync(),
            isTrue,
            reason:
                'Missing golden $goldenDir/${f.key} — run with UPDATE_GOLDENS=1',
          );
          expect(
            f.value,
            equals(goldenFile.readAsStringSync()),
            reason:
                'Output drift in ${f.key} — review and run UPDATE_GOLDENS=1 if intended',
          );
        }

        // No stale goldens that the generator no longer emits.
        final goldenRoot = Directory(goldenDir);
        if (goldenRoot.existsSync()) {
          final onDisk = goldenRoot
              .listSync(recursive: true)
              .whereType<File>()
              .map((f) => p.relative(f.path, from: goldenDir))
              .toSet();
          expect(
            onDisk,
            equals(rendered.keys.toSet()),
            reason:
                'Golden set differs from rendered set — run UPDATE_GOLDENS=1',
          );
        }
      });
    }
  });
}
