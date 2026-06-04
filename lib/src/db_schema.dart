/// Fetches the actual database schema from a running local Supabase instance.
library;

import 'package:postgres/postgres.dart';

class DbSchema {
  final Map<String, DbTable> tables;
  final Map<String, List<String>> enumValues;

  const DbSchema({required this.tables, required this.enumValues});

  static Future<DbSchema> fetch({
    String host = '127.0.0.1',
    int port = 56322,
    String database = 'postgres',
    String username = 'postgres',
    String password = 'postgres',
  }) async {
    final conn = await Connection.open(
      Endpoint(
        host: host,
        port: port,
        database: database,
        username: username,
        password: password,
      ),
      settings: ConnectionSettings(sslMode: SslMode.disable),
    );

    try {
      final tables = await _fetchTables(conn);
      final enumValues = await _fetchEnumValues(conn);
      return DbSchema(tables: tables, enumValues: enumValues);
    } finally {
      await conn.close();
    }
  }

  static Future<Map<String, DbTable>> _fetchTables(Connection conn) async {
    final result = await conn.execute('''
      SELECT
        c.table_name,
        c.column_name,
        c.data_type,
        c.udt_name,
        c.is_nullable,
        c.column_default,
        c.character_maximum_length
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON c.table_schema = t.table_schema
       AND c.table_name = t.table_name
      WHERE c.table_schema = 'public'
        AND t.table_type = 'BASE TABLE'
      ORDER BY c.table_name, c.ordinal_position
    ''');

    final tables = <String, DbTable>{};
    for (final row in result) {
      final tableName = row[0] as String;
      final col = DbColumn(
        name: row[1] as String,
        dataType: row[2] as String,
        udtName: row[3] as String,
        isNullable: row[4] as String == 'YES',
        defaultValue: row[5] as String?,
        maxLength: row[6] as int?,
      );
      tables.putIfAbsent(
        tableName,
        () => DbTable(name: tableName, columns: []),
      );
      tables[tableName]!.columns.add(col);
    }
    return tables;
  }

  static Future<Map<String, List<String>>> _fetchEnumValues(
    Connection conn,
  ) async {
    final result = await conn.execute('''
      SELECT t.typname, e.enumlabel
      FROM pg_enum e
      JOIN pg_type t ON e.enumtypid = t.oid
      JOIN pg_namespace n ON t.typnamespace = n.oid
      WHERE n.nspname = 'public'
      ORDER BY t.typname, e.enumsortorder
    ''');

    final enums = <String, List<String>>{};
    for (final row in result) {
      final name = row[0] as String;
      final value = row[1] as String;
      enums.putIfAbsent(name, () => []);
      enums[name]!.add(value);
    }
    return enums;
  }

  Set<String> missingFromContract(Set<String> contractNames) =>
      tables.keys.toSet().difference(contractNames);

  Set<String> missingFromDb(Set<String> contractNames) =>
      contractNames.difference(tables.keys.toSet());
}

class DbTable {
  final String name;
  final List<DbColumn> columns;
  const DbTable({required this.name, required this.columns});
  Map<String, DbColumn> get columnMap => {for (final c in columns) c.name: c};
}

class DbColumn {
  final String name;
  final String dataType;
  final String udtName;
  final bool isNullable;
  final String? defaultValue;
  final int? maxLength;

  const DbColumn({
    required this.name,
    required this.dataType,
    required this.udtName,
    required this.isNullable,
    this.defaultValue,
    this.maxLength,
  });

  String get effectiveType => dataType == 'USER-DEFINED' ? udtName : dataType;
  String get contractType => dataType == 'USER-DEFINED' ? udtName : dataType;

  @override
  String toString() => '$effectiveType${isNullable ? '?' : ''}';
}
