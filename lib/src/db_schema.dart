/// Fetches the actual database schema from a running local Supabase instance.
library;

import 'package:postgres/postgres.dart';

class DbSchema {
  final Map<String, DbTable> tables;
  final Map<String, List<String>> enumValues;

  /// Views in the public schema (name → columns), fetched alongside tables.
  final Map<String, DbTable> views;

  /// Primary key columns per table, in index order (composite keys keep order).
  final Map<String, List<String>> primaryKeys;

  /// Callable functions in the public schema (excluding trigger functions and
  /// extension-owned functions), keyed by name.
  final Map<String, DbFunction> functions;

  /// Tables in the `supabase_realtime` publication (public schema only).
  final Set<String> realtimeTables;

  /// Storage buckets (from `storage.buckets`), empty when the storage schema
  /// is not present (plain Postgres).
  final List<DbBucket> storageBuckets;

  /// Row-level-security flag per public table.
  final Map<String, bool> rlsEnabled;

  /// Public-schema views that do NOT set `security_invoker` — they run with
  /// the view owner's privileges (the Postgres default), bypassing RLS.
  final Set<String> securityDefinerViews;

  const DbSchema({
    required this.tables,
    required this.enumValues,
    this.views = const {},
    this.primaryKeys = const {},
    this.functions = const {},
    this.realtimeTables = const {},
    this.storageBuckets = const [],
    this.rlsEnabled = const {},
    this.securityDefinerViews = const {},
  });

  /// Connects to Postgres and snapshots the public schema.
  ///
  /// Provide [url] (a `postgres://user:pass@host:port/db` connection string, or
  /// the `SUPABASE_DB_URL` env value) to target any project. When [url] is null
  /// the individual parameters / local-Supabase defaults are used.
  static Future<DbSchema> fetch({
    String? url,
    String host = '127.0.0.1',
    int port = 56322,
    String database = 'postgres',
    String username = 'postgres',
    String password = 'postgres',
  }) async {
    final Endpoint endpoint;
    final SslMode sslMode;
    if (url != null && url.isNotEmpty) {
      final uri = Uri.parse(url);
      final userInfo = uri.userInfo.split(':');
      endpoint = Endpoint(
        host: uri.host,
        port: uri.hasPort ? uri.port : 5432,
        database:
            uri.pathSegments.isNotEmpty ? uri.pathSegments.first : 'postgres',
        username:
            userInfo.isNotEmpty ? Uri.decodeComponent(userInfo[0]) : 'postgres',
        password: userInfo.length > 1 ? Uri.decodeComponent(userInfo[1]) : '',
      );
      // Require SSL for non-local hosts, disable for localhost (local Supabase).
      final isLocal = uri.host == '127.0.0.1' || uri.host == 'localhost';
      final sslParam = uri.queryParameters['sslmode'];
      sslMode = sslParam == 'disable' || (sslParam == null && isLocal)
          ? SslMode.disable
          : SslMode.require;
    } else {
      endpoint = Endpoint(
        host: host,
        port: port,
        database: database,
        username: username,
        password: password,
      );
      sslMode = SslMode.disable;
    }

    final conn = await Connection.open(
      endpoint,
      settings: ConnectionSettings(sslMode: sslMode),
    );

    try {
      final tables = await _fetchRelations(conn, 'BASE TABLE');
      final views = await _fetchRelations(conn, 'VIEW');
      final enumValues = await _fetchEnumValues(conn);
      final primaryKeys = await _fetchPrimaryKeys(conn);
      final functions = await _fetchFunctions(conn);
      final realtimeTables = await _fetchRealtimeTables(conn);
      final storageBuckets = await _fetchStorageBuckets(conn);
      final rlsEnabled = await _fetchRlsEnabled(conn);
      final securityDefinerViews = await _fetchSecurityDefinerViews(conn);
      return DbSchema(
        tables: tables,
        enumValues: enumValues,
        views: views,
        primaryKeys: primaryKeys,
        functions: functions,
        realtimeTables: realtimeTables,
        storageBuckets: storageBuckets,
        rlsEnabled: rlsEnabled,
        securityDefinerViews: securityDefinerViews,
      );
    } finally {
      await conn.close();
    }
  }

  static Future<Map<String, DbTable>> _fetchRelations(
    Connection conn,
    String tableType,
  ) async {
    final result = await conn.execute(
      Sql.named('''
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
        AND t.table_type = @tableType
      ORDER BY c.table_name, c.ordinal_position
    '''),
      parameters: {'tableType': tableType},
    );

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

  static Future<Map<String, List<String>>> _fetchPrimaryKeys(
    Connection conn,
  ) async {
    final result = await conn.execute('''
      SELECT c.relname, a.attname, array_position(i.indkey, a.attnum)
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
      WHERE i.indisprimary AND n.nspname = 'public'
      ORDER BY c.relname, array_position(i.indkey, a.attnum)
    ''');

    final keys = <String, List<String>>{};
    for (final row in result) {
      keys.putIfAbsent(row[0] as String, () => []).add(row[1] as String);
    }
    return keys;
  }

  /// Fetches callable public-schema functions. Trigger/event-trigger functions
  /// and functions owned by extensions are excluded — they are not part of the
  /// client RPC surface.
  static Future<Map<String, DbFunction>> _fetchFunctions(
    Connection conn,
  ) async {
    final result = await conn.execute('''
      SELECT
        p.proname,
        pg_get_function_arguments(p.oid),
        pg_get_function_result(p.oid),
        p.prosecdef,
        p.proconfig
      FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname = 'public'
        AND p.prokind = 'f'
        AND pg_get_function_result(p.oid) NOT IN ('trigger', 'event_trigger')
        AND NOT EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.objid = p.oid AND d.deptype = 'e'
        )
      ORDER BY p.proname
    ''');

    final functions = <String, DbFunction>{};
    for (final row in result) {
      final config = row[4];
      final configList = config is List
          ? config.map((e) => e.toString()).toList()
          : const <String>[];
      functions[row[0] as String] = DbFunction.parse(
        name: row[0] as String,
        argumentSignature: row[1] as String? ?? '',
        returnSignature: row[2] as String? ?? 'void',
        isSecurityDefiner: row[3] as bool? ?? false,
        hasSearchPath:
            configList.any((c) => c.startsWith('search_path=')),
      );
    }
    return functions;
  }

  static Future<Set<String>> _fetchRealtimeTables(Connection conn) async {
    final result = await conn.execute('''
      SELECT tablename FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
      ORDER BY tablename
    ''');
    return {for (final row in result) row[0] as String};
  }

  static Future<List<DbBucket>> _fetchStorageBuckets(Connection conn) async {
    try {
      final result = await conn.execute('''
        SELECT name, public, file_size_limit, allowed_mime_types
        FROM storage.buckets
        ORDER BY name
      ''');
      return [
        for (final row in result)
          DbBucket(
            name: row[0] as String,
            public: row[1] as bool? ?? false,
            fileSizeLimitBytes: row[2] as int?,
            allowedMimeTypes: row[3] is List
                ? (row[3] as List).map((e) => e.toString()).toList()
                : const [],
          ),
      ];
    } catch (_) {
      // No storage schema (plain Postgres) — not an error.
      return const [];
    }
  }

  static Future<Map<String, bool>> _fetchRlsEnabled(Connection conn) async {
    final result = await conn.execute('''
      SELECT c.relname, c.relrowsecurity
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
      ORDER BY c.relname
    ''');
    return {for (final row in result) row[0] as String: row[1] as bool};
  }

  static Future<Set<String>> _fetchSecurityDefinerViews(
    Connection conn,
  ) async {
    final result = await conn.execute('''
      SELECT c.relname, c.reloptions
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'v'
      ORDER BY c.relname
    ''');
    final views = <String>{};
    for (final row in result) {
      final options = row[1];
      final optionList = options is List
          ? options.map((e) => e.toString()).toList()
          : const <String>[];
      final invoker = optionList.any((o) =>
          o == 'security_invoker=true' ||
          o == 'security_invoker=on' ||
          o == 'security_invoker=1');
      if (!invoker) views.add(row[0] as String);
    }
    return views;
  }

  Set<String> missingFromContract(Set<String> contractNames) =>
      tables.keys.toSet().difference(contractNames);

  Set<String> missingFromDb(Set<String> contractNames) =>
      contractNames.difference(tables.keys.toSet());
}

/// A callable Postgres function in the public schema.
class DbFunction {
  final String name;

  /// Ordered argument name → Postgres type. Unnamed arguments are skipped
  /// (they cannot be called by name via PostgREST anyway).
  final Map<String, String> args;

  /// Arguments that carry a `DEFAULT` in the function signature.
  final List<String> optionalArgs;

  /// Raw result signature, e.g. `uuid`, `SETOF sessions`, `TABLE(id uuid)`.
  final String returns;

  final bool isSecurityDefiner;

  /// Whether the function pins `search_path` via `SET search_path = ...`.
  final bool hasSearchPath;

  /// True when the argument signature contained parts that could not be
  /// parsed into `name type` pairs (OUT-only params, unnamed args, ...).
  final bool argsIncomplete;

  const DbFunction({
    required this.name,
    required this.args,
    required this.optionalArgs,
    required this.returns,
    required this.isSecurityDefiner,
    required this.hasSearchPath,
    this.argsIncomplete = false,
  });

  /// Parses `pg_get_function_arguments` output such as
  /// `p_id uuid, p_note text DEFAULT NULL::text, p_limit integer DEFAULT 10`.
  factory DbFunction.parse({
    required String name,
    required String argumentSignature,
    required String returnSignature,
    required bool isSecurityDefiner,
    required bool hasSearchPath,
  }) {
    final args = <String, String>{};
    final optionalArgs = <String>[];
    var incomplete = false;

    for (final part in _splitTopLevel(argumentSignature)) {
      var arg = part.trim();
      if (arg.isEmpty) continue;
      // Strip parameter modes; OUT params are results, not call arguments.
      if (arg.startsWith('OUT ')) continue;
      if (arg.startsWith('INOUT ')) arg = arg.substring(6);
      if (arg.startsWith('IN ')) arg = arg.substring(3);
      if (arg.startsWith('VARIADIC ')) arg = arg.substring(9);

      final hasDefault = arg.contains(' DEFAULT ');
      if (hasDefault) arg = arg.substring(0, arg.indexOf(' DEFAULT '));

      final space = arg.indexOf(' ');
      final nameMatch =
          space > 0 ? RegExp(r'^[a-z_][a-z0-9_]*$').firstMatch(arg.substring(0, space)) : null;
      if (nameMatch == null) {
        incomplete = true; // unnamed argument — cannot be projected
        continue;
      }
      final argName = arg.substring(0, space);
      final argType = arg.substring(space + 1).trim();
      args[argName] = argType;
      if (hasDefault) optionalArgs.add(argName);
    }

    return DbFunction(
      name: name,
      args: args,
      optionalArgs: optionalArgs,
      returns: returnSignature.trim(),
      isSecurityDefiner: isSecurityDefiner,
      hasSearchPath: hasSearchPath,
      argsIncomplete: incomplete,
    );
  }

  /// Splits on commas that are not nested inside parentheses
  /// (`numeric(10,2)` stays whole).
  static List<String> _splitTopLevel(String s) {
    final parts = <String>[];
    var depth = 0;
    var start = 0;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == '(') depth++;
      if (ch == ')') depth--;
      if (ch == ',' && depth == 0) {
        parts.add(s.substring(start, i));
        start = i + 1;
      }
    }
    parts.add(s.substring(start));
    return parts;
  }
}

/// A storage bucket row from `storage.buckets`.
class DbBucket {
  final String name;
  final bool public;
  final int? fileSizeLimitBytes;
  final List<String> allowedMimeTypes;

  const DbBucket({
    required this.name,
    required this.public,
    this.fileSizeLimitBytes,
    this.allowedMimeTypes = const [],
  });
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
