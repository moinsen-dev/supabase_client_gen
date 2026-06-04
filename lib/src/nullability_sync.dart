/// Materialises live-DB column nullability into the contract's `nullable_fields`
/// lists. The DB stays the source of truth, but its truth is written *into* the
/// contract so that code generation can remain deterministic and DB-independent.
library;

import 'dart:io';

import 'package:yaml_edit/yaml_edit.dart';

import 'contract_loader.dart';
import 'db_schema.dart';

/// Updates `data_model.public.<table>.nullable_fields` in the contract at
/// [contractPath] to match [db]. Only fields declared in the contract are
/// considered. Edits are surgical (comments/formatting preserved).
///
/// Returns the number of field-level changes applied (additions + removals).
int syncNullabilityIntoContract(String contractPath, DbSchema db) {
  final contract = loadContract(contractPath);
  final editor = YamlEditor(File(contractPath).readAsStringSync());
  var changes = 0;

  for (final entry in contract.publicTables.entries) {
    final tableName = entry.key;
    final table = entry.value;
    final dbTable = db.tables[tableName];
    if (dbTable == null) continue;
    final cols = dbTable.columnMap;

    final desired = <String>[
      for (final field in table.fields.keys)
        if (cols[field]?.isNullable ?? false) field,
    ]..sort();
    final current = [...?table.nullableFields]..sort();

    final added = desired.where((f) => !current.contains(f)).length;
    final removed = current.where((f) => !desired.contains(f)).length;
    if (added == 0 && removed == 0) continue;
    changes += added + removed;

    final path = ['data_model', 'public', tableName, 'nullable_fields'];
    if (desired.isEmpty) {
      try {
        editor.remove(path);
      } catch (_) {
        // Key wasn't present; nothing to remove.
      }
    } else {
      editor.update(path, desired);
    }
  }

  if (changes > 0) {
    File(contractPath).writeAsStringSync(editor.toString());
  }
  return changes;
}
