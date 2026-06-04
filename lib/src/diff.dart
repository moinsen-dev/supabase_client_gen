/// Compares the actual database schema against the contract YAML
/// and reports every detected drift.
library;

import 'contract.dart';
import 'db_schema.dart';

class SchemaDiff {
  final List<DiffEntry> entries;

  const SchemaDiff(this.entries);

  bool get isClean => entries.isEmpty;

  String format() {
    if (entries.isEmpty) return 'OK: DB schema matches contract.';
    final b = StringBuffer();
    for (final e in entries) {
      b.writeln('  ${e.severityIcon} ${e.message}');
    }
    b.writeln();
    b.writeln('${entries.length} drift(s) detected.');
    return b.toString();
  }
}

class DiffEntry {
  final DiffSeverity severity;
  final String table;
  final String? column;
  final String message;

  const DiffEntry({
    required this.severity,
    required this.table,
    this.column,
    required this.message,
  });

  String get severityIcon => switch (severity) {
        DiffSeverity.error => '✗',
        DiffSeverity.warning => '⚠',
        DiffSeverity.info => 'ℹ',
      };
}

enum DiffSeverity { error, warning, info }

/// Builds a diff between the actual DB schema and the contract.
SchemaDiff diffSchema(DbSchema db, SupabaseContract contract) {
  final entries = <DiffEntry>[];
  final contractTables = contract.publicTables;

  // Tables in DB but not in contract
  for (final name in db.missingFromContract(contractTables.keys.toSet())) {
    entries.add(
      DiffEntry(
        severity: DiffSeverity.error,
        table: name,
        message: "Table 'public.$name' exists in DB but not in contract",
      ),
    );
  }

  // Tables in contract but not in DB
  for (final name in db.missingFromDb(contractTables.keys.toSet())) {
    entries.add(
      DiffEntry(
        severity: DiffSeverity.error,
        table: name,
        message: "Table 'public.$name' in contract does not exist in DB",
      ),
    );
  }

  // Column-level comparison
  for (final entry in contractTables.entries) {
    final tableName = entry.key;
    final contractTable = entry.value;
    final dbTable = db.tables[tableName];
    if (dbTable == null) continue; // already reported above

    final dbCols = dbTable.columnMap;

    // Columns in DB but not in contract
    for (final dbCol in dbTable.columns) {
      if (!contractTable.fields.containsKey(dbCol.name)) {
        entries.add(
          DiffEntry(
            severity: DiffSeverity.warning,
            table: tableName,
            column: dbCol.name,
            message:
                "Column '$tableName.${dbCol.name}' ($dbCol) exists in DB but not in contract",
          ),
        );
      }
    }

    // Columns in contract but not in DB
    for (final fieldName in contractTable.fields.keys) {
      if (!dbCols.containsKey(fieldName)) {
        entries.add(
          DiffEntry(
            severity: DiffSeverity.error,
            table: tableName,
            column: fieldName,
            message:
                "Column '$tableName.$fieldName' in contract does not exist in DB",
          ),
        );
      }
    }

    // Type mismatches
    for (final fieldName in contractTable.fields.keys) {
      final dbCol = dbCols[fieldName];
      if (dbCol == null) continue;

      final contractType = contractTable.fields[fieldName]!;
      final dbType = dbCol.contractType;

      if (!_typesCompatible(contractType, dbType)) {
        entries.add(
          DiffEntry(
            severity: DiffSeverity.error,
            table: tableName,
            column: fieldName,
            message:
                "Type mismatch: '$tableName.$fieldName' is '$dbType' in DB but '$contractType' in contract",
          ),
        );
      }

      // Nullable mismatch — the contract tracks nullability via `nullable_fields`.
      final contractNullable =
          contractTable.nullableFields?.contains(fieldName) ?? false;
      if (!contractNullable && dbCol.isNullable) {
        entries.add(
          DiffEntry(
            severity: DiffSeverity.info,
            table: tableName,
            column: dbCol.name,
            message:
                "Column '$tableName.${dbCol.name}' is nullable in DB but not marked in contract.nullable_fields — run `generate --with-db --sync-nullability`",
          ),
        );
      } else if (contractNullable && !dbCol.isNullable) {
        entries.add(
          DiffEntry(
            severity: DiffSeverity.warning,
            table: tableName,
            column: dbCol.name,
            message:
                "Column '$tableName.${dbCol.name}' is marked nullable in contract but is NOT NULL in DB",
          ),
        );
      }
    }
  }

  // Enum comparison
  for (final entry in contractTables.entries) {
    final contractTable = entry.value;
    if (contractTable.enumValues == null) continue;

    for (final enumEntry in contractTable.enumValues!.entries) {
      final enumName = enumEntry.key;
      final contractValues = enumEntry.value.toSet();
      final dbValues = (db.enumValues[enumName] ?? []).toSet();

      final missingInDb = contractValues.difference(dbValues);
      final missingInContract = dbValues.difference(contractValues);

      for (final v in missingInDb) {
        entries.add(
          DiffEntry(
            severity: DiffSeverity.error,
            table: entry.key,
            message: "Enum '$enumName' value '$v' in contract but not in DB",
          ),
        );
      }
      for (final v in missingInContract) {
        entries.add(
          DiffEntry(
            severity: DiffSeverity.warning,
            table: entry.key,
            message: "Enum '$enumName' value '$v' in DB but not in contract",
          ),
        );
      }
    }
  }

  // Enums in DB not referenced by any contract table
  for (final dbEnum in db.enumValues.keys) {
    var found = false;
    for (final table in contractTables.values) {
      if (table.enumValues != null && table.enumValues!.containsKey(dbEnum)) {
        found = true;
        break;
      }
    }
    if (!found) {
      entries.add(
        DiffEntry(
          severity: DiffSeverity.info,
          table: '(enums)',
          message: "Enum '$dbEnum' exists in DB but not referenced in contract",
        ),
      );
    }
  }

  return SchemaDiff(entries);
}

/// Checks if a contract type is compatible with the actual DB type.
bool _typesCompatible(String contractType, String dbType) {
  // Normalize both
  final c = _normalizeType(contractType);
  final d = _normalizeType(dbType);

  if (c == d) return true;

  // Known equivalences
  const equivalents = {
    {'text', 'character varying'},
    {'integer', 'int4'},
    {'bigint', 'int8'},
    {'boolean', 'bool'},
    {'timestamptz', 'timestamp with time zone'},
    {'jsonb', 'json'},
  };

  for (final eq in equivalents) {
    if (eq.contains(c) && eq.contains(d)) return true;
  }

  return false;
}

String _normalizeType(String t) => t.toLowerCase().trim();
