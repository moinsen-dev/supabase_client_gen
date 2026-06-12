/// Brownfield import: builds a `supabase.yaml` contract draft from an existing
/// backend — either a live database snapshot ([buildContractFromDb]) or a
/// `supabase gen types` TypeScript file ([buildContractFromGenTypes]).
///
/// The draft is a starting point, not a finished contract: every place a human
/// must decide (client_access, ownership, project ref, descriptions) carries a
/// `# TODO review` marker. Output is deterministic — entries are sorted
/// alphabetically (enum *values* keep their semantic Postgres order), so the
/// same input always produces a byte-identical file.
library;

import 'db_schema.dart';
import 'gen_types.dart';

/// Builds a contract draft from a live-DB snapshot.
///
/// [date] becomes `contract.date` — pass a fixed value for reproducible tests;
/// the CLI passes today. The builder itself reads no ambient state.
String buildContractFromDb(
  DbSchema db, {
  required String projectName,
  required String date,
}) {
  final knownTables = db.tables.keys.toSet();
  final tables = <_DraftTable>[];

  for (final name in db.tables.keys.toList()..sort()) {
    final dbTable = db.tables[name]!;
    final fields = <String, String>{};
    final nullable = <String>[];
    final enumsUsed = <String, List<String>>{};
    final fieldComments = <String, String>{};

    for (final col in dbTable.columns) {
      final raw = col.dataType == 'ARRAY' ? col.udtName : col.contractType;
      final mapped = _contractTypeFromPg(raw, db.enumValues.keys.toSet());
      if (mapped == null) {
        fields[col.name] = 'text';
        fieldComments[col.name] =
            "# TODO review: unmapped Postgres type '$raw'";
      } else {
        fields[col.name] = mapped;
        if (db.enumValues.containsKey(mapped)) {
          enumsUsed[mapped] = db.enumValues[mapped]!;
        }
      }
      if (col.isNullable) nullable.add(col.name);
    }

    final pk = db.primaryKeys[name];
    tables.add(_DraftTable(
      name: name,
      isView: false,
      primaryKey: pk ?? _guessPrimaryKey(fields.keys),
      pkGuessed: pk == null,
      fields: fields,
      fieldComments: fieldComments,
      nullableFields: nullable..sort(),
      enumValues: enumsUsed,
    ));
  }

  for (final name in db.views.keys.toList()..sort()) {
    final dbView = db.views[name]!;
    final fields = <String, String>{};
    final fieldComments = <String, String>{};
    final enumsUsed = <String, List<String>>{};
    for (final col in dbView.columns) {
      final raw = col.dataType == 'ARRAY' ? col.udtName : col.contractType;
      final mapped = _contractTypeFromPg(raw, db.enumValues.keys.toSet());
      if (mapped == null) {
        fields[col.name] = 'text';
        fieldComments[col.name] =
            "# TODO review: unmapped Postgres type '$raw'";
      } else {
        fields[col.name] = mapped;
        if (db.enumValues.containsKey(mapped)) {
          enumsUsed[mapped] = db.enumValues[mapped]!;
        }
      }
    }
    tables.add(_DraftTable(
      name: name,
      isView: true,
      primaryKey: _guessPrimaryKey(fields.keys),
      pkGuessed: true,
      fields: fields,
      fieldComments: fieldComments,
      nullableFields: const [],
      enumValues: enumsUsed,
    ));
  }
  tables.sort((a, b) => a.name.compareTo(b.name));

  final functions = <_DraftFunction>[];
  for (final name in db.functions.keys.toList()..sort()) {
    final fn = db.functions[name]!;
    final args = <String, String>{};
    final argComments = <String, String>{};
    for (final argName in fn.args.keys.toList()..sort()) {
      final mapped =
          _contractTypeFromPg(fn.args[argName]!, db.enumValues.keys.toSet());
      if (mapped == null) {
        args[argName] = 'text';
        argComments[argName] =
            "# TODO review: unmapped Postgres type '${fn.args[argName]}'";
      } else {
        args[argName] = mapped;
      }
    }
    functions.add(_DraftFunction(
      name: name,
      args: args,
      argComments: argComments,
      optionalArgs: fn.optionalArgs.toList()..sort(),
      returns: _mapReturns(fn.returns, knownTables),
      argsIncomplete: fn.argsIncomplete,
    ));
  }

  final buckets = [
    for (final b in db.storageBuckets)
      _DraftBucket(
        name: b.name,
        public: b.public,
        allowedMimeTypes: b.allowedMimeTypes.toList()..sort(),
        fileSizeLimitMb: b.fileSizeLimitBytes != null
            ? (b.fileSizeLimitBytes! / (1024 * 1024)).round()
            : null,
      ),
  ]..sort((a, b) => a.name.compareTo(b.name));

  return _emitYaml(
    projectName: projectName,
    date: date,
    sourceNote: 'live database introspection (init --from-db)',
    tables: tables,
    functions: functions,
    buckets: buckets,
    realtimeTables: db.realtimeTables.toList()..sort(),
    offline: false,
  );
}

/// Builds a contract draft from a parsed `supabase gen types` file — the
/// offline variant. TypeScript types are lossy (uuid and timestamptz both
/// surface as `string`), so the field types are approximations; storage
/// buckets and the realtime publication are not recoverable at all.
String buildContractFromGenTypes(
  GenTypes types, {
  required String projectName,
  required String date,
}) {
  final tables = <_DraftTable>[];

  void addRelation(String name, Map<String, String> rowTypes, bool isView) {
    final fields = <String, String>{};
    final nullable = <String>[];
    final enumsUsed = <String, List<String>>{};
    for (final col in rowTypes.keys.toList()..sort()) {
      final parsed = _contractTypeFromTs(rowTypes[col]!, types.enumValues);
      fields[col] = parsed.type;
      if (parsed.nullable && !isView) nullable.add(col);
      if (types.enumValues.containsKey(parsed.type)) {
        enumsUsed[parsed.type] = types.enumValues[parsed.type]!;
      }
    }
    tables.add(_DraftTable(
      name: name,
      isView: isView,
      primaryKey: _guessPrimaryKey(fields.keys),
      pkGuessed: true,
      fields: fields,
      fieldComments: const {},
      nullableFields: nullable..sort(),
      enumValues: enumsUsed,
    ));
  }

  for (final name in types.tableNames.toList()..sort()) {
    addRelation(name, types.rowTypes[name] ?? const {}, false);
  }
  for (final name in types.viewNames.toList()..sort()) {
    addRelation(name, types.viewRowTypes[name] ?? const {}, true);
  }
  tables.sort((a, b) => a.name.compareTo(b.name));

  final functions = [
    for (final name in types.functionNames.toList()..sort())
      _DraftFunction(
        name: name,
        args: const {},
        argComments: const {},
        optionalArgs: const [],
        returns: 'json',
        argsIncomplete: true,
      ),
  ];

  return _emitYaml(
    projectName: projectName,
    date: date,
    sourceNote: 'a supabase gen-types file (init --from-gen-types)',
    tables: tables,
    functions: functions,
    buckets: const [],
    realtimeTables: const [],
    offline: true,
  );
}

// ---------------------------------------------------------------------------
// Type mapping
// ---------------------------------------------------------------------------

/// Maps a Postgres type name (udt or verbose information_schema spelling) to
/// the contract's type vocabulary, or null when unknown.
String? _contractTypeFromPg(String pgType, Set<String> enumNames) {
  var t = pgType.toLowerCase().trim();
  // Strip length/precision qualifiers: varchar(255), numeric(10,2).
  t = t.replaceAll(RegExp(r'\(\s*\d+(\s*,\s*\d+)?\s*\)'), '');
  switch (t) {
    case 'uuid':
      return 'uuid';
    case 'text':
    case 'character varying':
    case 'varchar':
    case 'character':
    case 'bpchar':
    case 'citext':
      return 'text';
    case 'smallint':
    case 'int2':
    case 'integer':
    case 'int4':
      return 'integer';
    case 'bigint':
    case 'int8':
      return 'bigint';
    case 'numeric':
    case 'decimal':
    case 'real':
    case 'float4':
    case 'double precision':
    case 'float8':
      return 'numeric';
    case 'boolean':
    case 'bool':
      return 'boolean';
    case 'timestamp with time zone':
    case 'timestamptz':
      return 'timestamptz';
    case 'timestamp without time zone':
    case 'timestamp':
      return 'timestamp';
    case 'date':
      return 'date';
    case 'jsonb':
      return 'jsonb';
    case 'json':
      return 'json';
    case 'text[]':
    case '_text':
      return 'text[]';
  }
  if (t.startsWith('vector')) return pgType.trim();
  if (enumNames.contains(pgType.trim())) return pgType.trim();
  return null;
}

class _TsType {
  final String type;
  final bool nullable;
  const _TsType(this.type, this.nullable);
}

/// Maps a raw TypeScript Row type (e.g. `string | null`,
/// `Database["public"]["Enums"]["mood"]`) to a contract type.
_TsType _contractTypeFromTs(String raw, Map<String, List<String>> enums) {
  var t = raw.trim();
  var nullable = false;
  if (t.endsWith('| null')) {
    nullable = true;
    t = t.substring(0, t.length - 6).trim();
  }
  final enumRef =
      RegExp(r'Database\["public"\]\["Enums"\]\["(\w+)"\]').firstMatch(t);
  if (enumRef != null) return _TsType(enumRef.group(1)!, nullable);
  switch (t) {
    case 'string':
      return _TsType('text', nullable);
    case 'number':
      return _TsType('numeric', nullable);
    case 'boolean':
      return _TsType('boolean', nullable);
    case 'Json':
      return _TsType('jsonb', nullable);
    case 'string[]':
      return _TsType('text[]', nullable);
  }
  return _TsType('text', nullable);
}

/// Maps a Postgres function result signature onto the contract's `returns`
/// vocabulary. Conservative: known scalars map directly, `SETOF <table>` /
/// `<table>` map to rows:/row: when the table is part of the data model,
/// everything else falls back to `json`.
String _mapReturns(String raw, Set<String> knownTables) {
  var r = raw.trim();
  if (r.toUpperCase().startsWith('SETOF ')) {
    final inner = r.substring(6).trim();
    if (knownTables.contains(inner)) return 'rows:$inner';
    return 'json';
  }
  switch (r.toLowerCase()) {
    case 'uuid':
      return 'uuid';
    case 'text':
    case 'character varying':
    case 'varchar':
      return 'text';
    case 'smallint':
    case 'int2':
    case 'integer':
    case 'int4':
    case 'bigint':
    case 'int8':
      return 'integer';
    case 'boolean':
    case 'bool':
      return 'boolean';
    case 'void':
      return 'void';
    case 'json':
    case 'jsonb':
      return 'json';
  }
  if (knownTables.contains(r)) return 'row:$r';
  return 'json';
}

List<String> _guessPrimaryKey(Iterable<String> fields) {
  if (fields.contains('id')) return const ['id'];
  final sorted = fields.toList()..sort();
  return sorted.isEmpty ? const ['id'] : [sorted.first];
}

// ---------------------------------------------------------------------------
// YAML emission
// ---------------------------------------------------------------------------

class _DraftTable {
  final String name;
  final bool isView;
  final List<String> primaryKey;
  final bool pkGuessed;
  final Map<String, String> fields;
  final Map<String, String> fieldComments;
  final List<String> nullableFields;
  final Map<String, List<String>> enumValues;

  const _DraftTable({
    required this.name,
    required this.isView,
    required this.primaryKey,
    required this.pkGuessed,
    required this.fields,
    required this.fieldComments,
    required this.nullableFields,
    required this.enumValues,
  });
}

class _DraftFunction {
  final String name;
  final Map<String, String> args;
  final Map<String, String> argComments;
  final List<String> optionalArgs;
  final String returns;
  final bool argsIncomplete;

  const _DraftFunction({
    required this.name,
    required this.args,
    required this.argComments,
    required this.optionalArgs,
    required this.returns,
    required this.argsIncomplete,
  });
}

class _DraftBucket {
  final String name;
  final bool public;
  final List<String> allowedMimeTypes;
  final int? fileSizeLimitMb;

  const _DraftBucket({
    required this.name,
    required this.public,
    required this.allowedMimeTypes,
    this.fileSizeLimitMb,
  });
}

String _emitYaml({
  required String projectName,
  required String date,
  required String sourceNote,
  required List<_DraftTable> tables,
  required List<_DraftFunction> functions,
  required List<_DraftBucket> buckets,
  required List<String> realtimeTables,
  required bool offline,
}) {
  final b = StringBuffer();

  b.writeln('# $projectName Supabase contract — DRAFT generated by '
      'supabase_client_gen:init.');
  b.writeln('#');
  b.writeln('# Source: $sourceNote.');
  b.writeln('# Review every `# TODO review` marker before adopting this '
      'contract:');
  b.writeln('#   - client_access defaults to select-for-authenticated and '
      'edge_function_only');
  b.writeln('#     writes — tighten or open per table to match your RLS '
      'policies.');
  b.writeln("#   - ownership is guessed from the presence of a workspace_id "
      'column.');
  if (offline) {
    b.writeln('#   - field types are approximated from TypeScript (uuid and '
        'timestamptz both');
    b.writeln('#     surface as string → text). Correct them against your '
        'schema.');
  }
  b.writeln('#');
  b.writeln('# Then generate the typed client:');
  b.writeln('#   dart pub global run supabase_client_gen:generate \\');
  b.writeln('#     --contract supabase.yaml --output lib/generated');
  b.writeln();

  b.writeln('contract:');
  b.writeln('  name: ${projectName}_supabase_contract');
  b.writeln('  version: "0.1.0"');
  b.writeln('  date: "$date"');
  b.writeln();

  b.writeln('project:');
  b.writeln('  remote:');
  b.writeln('    name: $projectName');
  b.writeln('    ref: TODO_PROJECT_REF # TODO review: set your Supabase '
      'project ref');
  b.writeln();

  b.writeln('auth:');
  b.writeln('  provider: supabase');
  b.writeln('  planned_sign_in_methods: # TODO review: list your actual '
      'sign-in methods');
  b.writeln('    - email');
  b.writeln();

  b.writeln('data_model:');
  if (tables.isEmpty) {
    b.writeln('  public: {}');
  } else {
    b.writeln('  public:');
    var first = true;
    for (final t in tables) {
      if (!first) b.writeln();
      first = false;
      b.writeln('    ${t.name}:');
      if (t.isView) b.writeln('      kind: view');
      final hasWorkspace = t.fields.containsKey('workspace_id');
      final ownership = hasWorkspace ? 'workspace' : 'global';
      final ownershipWhy = hasWorkspace
          ? 'guessed from workspace_id column'
          : 'guessed (no workspace_id column)';
      b.writeln('      ownership: $ownership # TODO review: $ownershipWhy');
      final pkComment = !t.pkGuessed
          ? ''
          : t.isView
              ? ' # TODO review: views have no PK in Postgres — pick the row '
                  'identity'
              : offline
                  ? ' # TODO review: not recoverable from gen-types — set '
                      'the real primary key'
                  : ' # TODO review: no primary key found in DB';
      if (t.primaryKey.length == 1) {
        b.writeln('      primary_key: ${t.primaryKey.first}$pkComment');
      } else {
        b.writeln('      primary_key: [${t.primaryKey.join(', ')}]$pkComment');
      }
      b.writeln('      # TODO review: add a description for this '
          '${t.isView ? 'view' : 'table'}.');
      b.writeln('      fields:');
      for (final f in t.fields.keys.toList()..sort()) {
        final comment =
            t.fieldComments.containsKey(f) ? ' ${t.fieldComments[f]}' : '';
        b.writeln('        $f: ${t.fields[f]}$comment');
      }
      if (t.nullableFields.isNotEmpty) {
        b.writeln('      nullable_fields:');
        for (final f in t.nullableFields) {
          b.writeln('        - $f');
        }
      }
      if (t.enumValues.isNotEmpty) {
        b.writeln('      enum_values:');
        for (final e in t.enumValues.keys.toList()..sort()) {
          // Enum values keep their Postgres sort order — it is semantic.
          b.writeln('        $e:');
          for (final v in t.enumValues[e]!) {
            b.writeln('          - ${_yamlScalar(v)}');
          }
        }
      }
      b.writeln('      client_access:');
      b.writeln('        select: authenticated # TODO review');
      if (!t.isView) {
        b.writeln('        insert: edge_function_only # TODO review');
        b.writeln('        update: edge_function_only # TODO review');
        b.writeln('        delete: edge_function_only # TODO review');
      }
    }
  }

  if (functions.isNotEmpty) {
    b.writeln();
    b.writeln('rpc_functions:');
    var first = true;
    for (final fn in functions) {
      if (!first) b.writeln();
      first = false;
      final incomplete = fn.argsIncomplete
          ? (offline
              ? ' # TODO review: args/returns are not recoverable from '
                  'gen-types — fill them in'
              : ' # TODO review: some arguments could not be introspected')
          : '';
      b.writeln('  ${fn.name}:$incomplete');
      b.writeln('    # TODO review: add a description.');
      if (fn.args.isNotEmpty) {
        b.writeln('    args:');
        for (final a in fn.args.keys) {
          final comment =
              fn.argComments.containsKey(a) ? ' ${fn.argComments[a]}' : '';
          b.writeln('      $a: ${fn.args[a]}$comment');
        }
      }
      if (fn.optionalArgs.isNotEmpty) {
        b.writeln('    optional_args:');
        for (final a in fn.optionalArgs) {
          b.writeln('      - $a');
        }
      }
      b.writeln('    returns: ${fn.returns}');
    }
  }

  if (buckets.isNotEmpty) {
    b.writeln();
    b.writeln('storage:');
    b.writeln('  buckets:');
    for (final bucket in buckets) {
      b.writeln('    ${bucket.name}:');
      b.writeln('      public: ${bucket.public}'
          '${bucket.public ? ' # TODO review: public buckets are readable by anyone' : ''}');
      if (bucket.allowedMimeTypes.isNotEmpty) {
        b.writeln('      allowed_mime_types:');
        for (final m in bucket.allowedMimeTypes) {
          b.writeln('        - ${_yamlScalar(m)}');
        }
      }
      if (bucket.fileSizeLimitMb != null) {
        b.writeln('      file_size_limit_mb: ${bucket.fileSizeLimitMb}');
      }
    }
  }

  b.writeln();
  b.writeln('# edge_functions cannot be introspected — declare any functions');
  b.writeln('# the client invokes manually (see README).');

  if (realtimeTables.isNotEmpty) {
    b.writeln();
    b.writeln('realtime:');
    b.writeln('  publication:');
    b.writeln('    allowed_tables:');
    for (final t in realtimeTables) {
      b.writeln('      - public.$t');
    }
  } else if (offline) {
    b.writeln();
    b.writeln('# realtime publication membership is not recoverable from '
        'gen-types —');
    b.writeln('# declare realtime.publication.allowed_tables manually if '
        'used.');
  }

  return b.toString();
}

/// Quotes a YAML scalar when needed (special characters, YAML keywords,
/// numeric look-alikes); identifiers pass through unquoted.
String _yamlScalar(String s) {
  final safe = RegExp(r'^[A-Za-z_][A-Za-z0-9_\-./+]*$');
  const keywords = {
    'true', 'false', 'null', 'yes', 'no', 'on', 'off', // YAML 1.1 booleans
  };
  if (safe.hasMatch(s) && !keywords.contains(s.toLowerCase())) return s;
  return "'${s.replaceAll("'", "''")}'";
}
