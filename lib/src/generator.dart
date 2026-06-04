/// Code generator: docs/contracts/supabase.yaml → Dart client code.
library;

import 'contract.dart';
import 'db_schema.dart';

class ClientGenerator {
  final SupabaseContract contract;
  final DbSchema? dbSchema;

  ClientGenerator(this.contract, {this.dbSchema});

  Map<String, String> generate() {
    final files = <String, String>{};

    for (final entry in contract.publicTables.entries) {
      final tableName = entry.key;
      final className = _className(tableName);
      files['models/${tableName}.dart'] = _generateModel(
        tableName,
        className,
        entry.value,
      );
    }

    files['enums/enums.dart'] = _generateAllEnums();

    for (final entry in contract.publicTables.entries) {
      final table = entry.value;
      if (!_isReadOnly(table)) {
        final className = _className(entry.key);
        files['repositories/${entry.key}_repository.dart'] =
            _generateRepository(entry.key, className, table);
      }
    }

    if (contract.edgeFunctions != null) {
      final clientFuncs = _clientInvokedFunctions();
      if (clientFuncs.isNotEmpty) {
        files['edge_functions/edge_functions.dart'] = _generateEdgeFunctions(
          clientFuncs,
        );
      }
    }

    files['models/models.dart'] = _barrel(
      contract.publicTables.keys.map((t) => "export '$t.dart';"),
    );
    files['repositories/repositories.dart'] = _barrel(
      contract.publicTables.entries
          .where((e) => !_isReadOnly(e.value))
          .map((e) => "export '${e.key}_repository.dart';"),
    );

    return files;
  }

  // ── Models ──────────────────────────────────────────────────────────

  String _generateModel(String tableName, String className, TableConfig table) {
    final b = StringBuffer();
    final fields = table.fields.keys.toList();

    b.writeln('// Generated from docs/contracts/supabase.yaml');
    b.writeln('// Table: public.$tableName');
    b.writeln();
    b.writeln("import 'package:equatable/equatable.dart';");
    if (_hasEnumFields(table)) b.writeln("import '../enums/enums.dart';");
    b.writeln();
    b.writeln('class $className extends Equatable {');
    b.writeln('  const $className({');
    for (final f in fields) {
      if (_isNullable(tableName, f)) {
        b.writeln('    this.${_camel(f)},');
      } else {
        b.writeln('    required this.${_camel(f)},');
      }
    }
    b.writeln('  });');
    b.writeln();

    for (final f in fields) {
      final type = _dartType(table, f);
      final nullable = _isNullable(tableName, f) ? '?' : '';
      b.writeln('  final $type$nullable ${_camel(f)};');
    }
    b.writeln();

    b.writeln('  $className copyWith({');
    for (final f in fields) {
      b.writeln('    ${_dartType(table, f)}? ${_camel(f)},');
    }
    b.writeln('  }) {');
    b.writeln('    return $className(');
    for (final f in fields) {
      final c = _camel(f);
      b.writeln('      $c: $c ?? this.$c,');
    }
    b.writeln('    );');
    b.writeln('  }');
    b.writeln();

    b.writeln('  factory $className.fromJson(Map<String, dynamic> json) {');
    b.writeln('    return $className(');
    for (final f in fields) {
      b.writeln('      ${_camel(f)}: ${_fromJsonExpr(table, f, tableName)},');
    }
    b.writeln('    );');
    b.writeln('  }');
    b.writeln();

    b.writeln('  Map<String, dynamic> toJson() {');
    b.writeln('    return {');
    for (final f in fields) {
      b.writeln("      '$f': ${_toJsonExpr(table, f, tableName)},");
    }
    b.writeln('    };');
    b.writeln('  }');
    b.writeln();

    b.writeln('  @override');
    b.writeln(
      '  List<Object?> get props => [${fields.map(_camel).join(', ')}];',
    );
    b.writeln('}');

    return b.toString();
  }

  String _fromJsonExpr(TableConfig table, String fieldName, String tableName) {
    final dt = _dartType(table, fieldName);
    final key = "json['$fieldName']";
    final nullable = _isNullable(tableName, fieldName);

    if (dt == 'DateTime') {
      return nullable
          ? "$key != null ? DateTime.parse($key as String) : null"
          : "$key != null ? DateTime.parse($key as String) : DateTime.now()";
    }
    if (dt == 'int')
      return nullable
          ? "($key as num?)?.toInt()"
          : "($key as num?)?.toInt() ?? 0";
    if (dt == 'double')
      return nullable
          ? "($key as num?)?.toDouble()"
          : "($key as num?)?.toDouble() ?? 0.0";
    if (dt == 'bool')
      return nullable ? "$key as bool?" : "$key as bool? ?? false";
    if (dt == 'Map<String, dynamic>')
      return nullable
          ? "$key as Map<String, dynamic>?"
          : "($key as Map<String, dynamic>?) ?? {}";
    if (dt == 'List<double>')
      return nullable
          ? "$key as List<double>?"
          : "($key as List<dynamic>?)?.map((e) => (e as num).toDouble()).toList() ?? []";
    if (table.isEnumField(fieldName)) {
      final enumName = _pascal(table.fields[fieldName]!);
      return nullable
          ? "$key != null ? $enumName.fromString($key as String) : null"
          : "$enumName.fromString($key as String? ?? '')";
    }
    return nullable ? "$key as String?" : "$key as String? ?? ''";
  }

  String _toJsonExpr(TableConfig table, String fieldName, String tableName) {
    final dt = _dartType(table, fieldName);
    final c = _camel(fieldName);
    final nullable = _isNullable(tableName, fieldName);
    if (dt == 'DateTime')
      return nullable ? '$c?.toIso8601String()' : '$c.toIso8601String()';
    if (table.isEnumField(fieldName)) return nullable ? '$c?.name' : '$c.name';
    return c;
  }

  // ── Enums ───────────────────────────────────────────────────────────

  String _generateAllEnums() {
    final all = <String, List<String>>{};
    for (final t in contract.publicTables.values) {
      if (t.enumValues != null) all.addAll(t.enumValues!);
    }
    final b = StringBuffer();
    b.writeln('// Generated from docs/contracts/supabase.yaml');
    b.writeln();
    for (final entry in all.entries) {
      final name = _pascal(entry.key);
      b.writeln('enum $name {');
      for (final v in entry.value) b.writeln('  ${_safeEnum(v)},');
      b.writeln(';');
      b.writeln();
      b.writeln('  static $name fromString(String value) {');
      b.writeln('    return $name.values.firstWhere(');
      b.writeln('      (e) => e.name == value,');
      b.writeln('      orElse: () => $name.${_safeEnum(entry.value.first)},');
      b.writeln('    );');
      b.writeln('  }');
      b.writeln('}');
      b.writeln();
    }
    return b.toString();
  }

  // ── Repositories ────────────────────────────────────────────────────

  bool _isReadOnly(TableConfig table) {
    final a = table.clientAccess;
    if (a == null) return true;
    final ins = a['insert'] ?? '',
        upd = a['update'] ?? '',
        del = a['delete'] ?? '';
    return ins == 'edge_function_only' &&
        upd == 'edge_function_only' &&
        del == 'edge_function_only';
  }

  String _generateRepository(
    String tableName,
    String className,
    TableConfig table,
  ) {
    final a = table.clientAccess ?? {};
    final sel = a['select'] ?? 'none';
    final ins = a['insert'] ?? 'none';
    final upd = a['update'] ?? 'none';
    final del = a['delete'] ?? 'none';
    final canIns = ins != 'edge_function_only' && ins != 'none';
    final canUpd = upd != 'edge_function_only' && upd != 'none';
    final canDel = del != 'edge_function_only' && del != 'none';
    final hasRealtime = contract.realtimePublicTables.contains(tableName);

    final b = StringBuffer();
    b.writeln('// Generated from docs/contracts/supabase.yaml');
    b.writeln('// Table: public.$tableName');
    b.writeln('// Access: select=$sel insert=$ins update=$upd delete=$del');
    if (hasRealtime) b.writeln('// Realtime: enabled');
    b.writeln();
    b.writeln("import 'dart:async';");
    b.writeln("import 'package:supabase_flutter/supabase_flutter.dart';");
    b.writeln("import '../models/${tableName}.dart';");
    b.writeln();
    b.writeln('class ${className}Repository {');
    b.writeln('  final SupabaseClient _client;');
    b.writeln('  const ${className}Repository(this._client);');
    b.writeln();

    if (sel != 'none') {
      final needsWs = sel.contains('workspace') || sel.contains('member');
      b.writeln('  /// Select: $sel');
      b.writeln('  Future<List<$className>> select({');
      if (needsWs) b.writeln('    required String workspaceId,');
      b.writeln('    int limit = 50,');
      b.writeln('    int offset = 0,');
      b.writeln('  }) async {');
      b.writeln("    var query = _client.from('$tableName').select();");
      if (needsWs)
        b.writeln("    query = query.eq('workspace_id', workspaceId);");
      b.writeln(
        '    final data = await query.limit(limit).range(offset, offset + limit - 1);',
      );
      b.writeln(
        '    return (data as List).map((j) => $className.fromJson(j)).toList();',
      );
      b.writeln('  }');
      b.writeln();
    }

    if (canIns) {
      b.writeln('  /// Insert: $ins');
      b.writeln(
        '  Future<$className> insert(Map<String, dynamic> data) async {',
      );
      b.writeln(
        "    final row = await _client.from('$tableName').insert(data).select().single();",
      );
      b.writeln('    return $className.fromJson(row);');
      b.writeln('  }');
      b.writeln();
    }

    if (canUpd) {
      b.writeln('  /// Update: $upd');
      b.writeln(
        '  Future<$className> update(String id, Map<String, dynamic> data) async {',
      );
      b.writeln(
        "    final row = await _client.from('$tableName').update(data).eq('id', id).select().single();",
      );
      b.writeln('    return $className.fromJson(row);');
      b.writeln('  }');
      b.writeln();
    }

    if (canDel) {
      b.writeln('  /// Delete: $del');
      b.writeln('  Future<void> delete(String id) async {');
      b.writeln("    await _client.from('$tableName').delete().eq('id', id);");
      b.writeln('  }');
      b.writeln();
    }

    if (hasRealtime) {
      b.writeln('  /// Realtime stream of changes to this table.');
      b.writeln('  Stream<List<$className>> stream({');
      b.writeln("    required String workspaceId,");
      b.writeln('  }) {');
      b.writeln("    return _client");
      b.writeln("        .from('$tableName')");
      b.writeln("        .stream(primaryKey: ['id'])");
      b.writeln("        .eq('workspace_id', workspaceId)");
      b.writeln('        .map((records) => (records as List)');
      b.writeln(
        '            .map((j) => $className.fromJson(j as Map<String, dynamic>))',
      );
      b.writeln('            .toList());');
      b.writeln('  }');
      b.writeln();
    }

    b.writeln('}');
    return b.toString();
  }

  // ── Edge Functions ──────────────────────────────────────────────────

  Map<String, EdgeFunctionConfig> _clientInvokedFunctions() {
    final result = <String, EdgeFunctionConfig>{};
    if (contract.edgeFunctions == null) return result;
    for (final entry in contract.edgeFunctions!.entries) {
      if (entry.key == 'runtime') continue;
      result[entry.key] = entry.value;
    }
    return result;
  }

  String _generateEdgeFunctions(Map<String, EdgeFunctionConfig> functions) {
    final b = StringBuffer();
    b.writeln('// Generated from docs/contracts/supabase.yaml');
    b.writeln('// Client-invoked edge functions');
    b.writeln();
    b.writeln("import 'package:supabase_flutter/supabase_flutter.dart';");
    b.writeln();

    for (final entry in functions.entries) {
      final fnName = entry.key;
      final fn = entry.value;
      final camel = _camel(fnName);

      // Collect all params from required + optional fields.
      final reqParams = fn.requiredFields
          .map((f) => _Param(f, _camel(f), true))
          .toList();
      final optParams = fn.optionalFields
          .map((f) => _Param(f, _camel(f), false))
          .toList();
      final allParams = [...reqParams, ...optParams];
      final hasParams = allParams.isNotEmpty;

      b.writeln('/// ${fn.description ?? 'Edge Function: $fnName'}');
      if (hasParams) {
        b.writeln('Future<Map<String, dynamic>> $camel({');
        for (final p in allParams) {
          final type = _fnParamType('text');
          final decl = p.required
              ? 'required $type ${p.dartName}'
              : '$type? ${p.dartName}';
          b.writeln('  $decl,');
        }
        b.writeln('}) async {');
      } else {
        b.writeln('Future<Map<String, dynamic>> $camel() async {');
      }
      b.writeln('  final client = Supabase.instance.client;');
      b.writeln('  final response = await client.functions.invoke(');
      b.writeln("    '$fnName',");
      b.writeln('    method: HttpMethod.${fn.method.toLowerCase()},');
      if (hasParams) {
        b.writeln('    body: {');
        for (final p in allParams) {
          b.writeln("      '${p.name}': ${p.dartName},");
        }
        b.writeln('    },');
      }
      b.writeln('  );');
      b.writeln('  return response.data as Map<String, dynamic>;');
      b.writeln('}');
      b.writeln();
    }
    return b.toString();
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  String _barrel(Iterable<String> exports) =>
      '// Generated barrel file\n\n${exports.join('\n')}\n';

  String _className(String tableName) => _pascal(_singular(tableName));

  bool _hasEnumFields(TableConfig table) =>
      table.fields.keys.any((f) => table.isEnumField(f));

  String _dartType(TableConfig table, String fieldName) {
    if (table.isEnumField(fieldName)) return _pascal(table.fields[fieldName]!);
    return table.dartType(fieldName);
  }

  bool _isNullable(String tableName, String fieldName) {
    final table = contract.publicTables[tableName];
    if (table?.nullableFields?.contains(fieldName) ?? false) return true;
    if (dbSchema != null) {
      final dbTable = dbSchema!.tables[tableName];
      final dbCol = dbTable?.columnMap[fieldName];
      if (dbCol != null) return dbCol.isNullable;
    }
    return false;
  }

  String _fnParamType(String pgType) => switch (pgType) {
    'uuid' || 'text' => 'String',
    'integer' || 'int4' => 'int',
    'boolean' || 'bool' => 'bool',
    'jsonb' || 'json' => 'Map<String, dynamic>',
    _ => 'String',
  };

  static const _reserved = {
    'new',
    'class',
    'enum',
    'const',
    'final',
    'var',
    'static',
    'void',
    'if',
    'else',
    'for',
    'while',
    'do',
    'switch',
    'case',
    'default',
    'break',
    'continue',
    'return',
    'throw',
    'try',
    'catch',
    'finally',
    'import',
    'export',
    'library',
    'part',
    'typedef',
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'hide',
    'show',
    'sync',
    'yield',
    'on',
    'in',
    'is',
    'operator',
    'factory',
    'get',
    'set',
    'with',
    'extends',
    'implements',
    'interface',
    'mixin',
    'super',
    'this',
    'true',
    'false',
    'null',
    'deferred',
    'dynamic',
    'covariant',
    'external',
    'Function',
    'late',
    'required',
    'sealed',
    'base',
  };

  String _safeEnum(String v) => _reserved.contains(v) ? '\$$v' : v;

  String _singular(String plural) {
    if (plural.endsWith('ies'))
      return '${plural.substring(0, plural.length - 3)}y';
    if (plural.endsWith('s') && !plural.endsWith('ss'))
      return plural.substring(0, plural.length - 1);
    return plural;
  }

  String _pascal(String s) => s
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join();

  String _camel(String s) {
    final p = _pascal(s);
    return p.isEmpty ? p : p[0].toLowerCase() + p.substring(1);
  }
}

class _Param {
  final String name;
  final String dartName;
  final bool required;
  const _Param(this.name, this.dartName, this.required);
}
