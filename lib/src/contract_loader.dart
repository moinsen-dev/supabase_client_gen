/// Loads and validates a `supabase.yaml` contract into a [SupabaseContract],
/// turning malformed YAML into actionable, path-qualified error messages
/// instead of raw `as String` cast crashes.
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

import 'contract.dart';

/// Thrown when a contract file is missing, unparseable, or structurally invalid.
/// The message names the offending path (e.g. `data_model.public.things.primary_key`).
class ContractError implements Exception {
  final String message;
  ContractError(this.message);
  @override
  String toString() => message;
}

/// Reads, parses, validates and builds the contract at [path].
SupabaseContract loadContract(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw ContractError('Contract file not found: $path');
  }

  final dynamic raw;
  try {
    raw = loadYaml(file.readAsStringSync());
  } catch (e) {
    throw ContractError('Could not parse YAML in $path:\n  $e');
  }

  final json = yamlToJson(raw);
  if (json is! Map<String, dynamic>) {
    throw ContractError(
      'Contract root must be a mapping, got ${json.runtimeType} in $path',
    );
  }

  _validate(json);

  try {
    return SupabaseContract.fromYaml(json);
  } on ContractError {
    rethrow;
  } catch (e) {
    // Defensive: any cast we didn't explicitly validate still gets the file context.
    throw ContractError('Invalid contract $path:\n  $e');
  }
}

/// Validates the structural shape a [SupabaseContract] depends on, reporting the
/// first problem with its location. Deliberately thin — covers the breakages
/// that actually happen with hand-edited YAML, not a full JSON-schema.
void _validate(Map<String, dynamic> root) {
  _requireMap(root, 'contract');
  final contract = root['contract'] as Map<String, dynamic>;
  for (final key in ['name', 'version', 'date']) {
    _requireString(contract, key, 'contract.$key');
  }

  _requireMap(root, 'project');
  final project = root['project'] as Map<String, dynamic>;
  if (project['remote'] is! Map) {
    throw ContractError(
      "project.remote is required and must be a mapping with 'name' and 'ref'. "
      "Note: the flat 'project: {name, organization, region}' form is not "
      "supported — wrap connection details under 'project.remote'.",
    );
  }
  final remote = (project['remote'] as Map).cast<String, dynamic>();
  _requireString(remote, 'name', 'project.remote.name');
  _requireString(remote, 'ref', 'project.remote.ref');

  _requireMap(root, 'auth');
  final auth = root['auth'] as Map<String, dynamic>;
  _requireString(auth, 'provider', 'auth.provider');
  if (auth['planned_sign_in_methods'] is! List) {
    throw ContractError(
        'auth.planned_sign_in_methods is required and must be a list.');
  }

  _requireMap(root, 'data_model');
  final dataModel = root['data_model'] as Map<String, dynamic>;
  for (final schemaEntry in dataModel.entries) {
    final schema = schemaEntry.key;
    if (schemaEntry.value is! Map) {
      throw ContractError('data_model.$schema must be a mapping of tables.');
    }
    final tables = (schemaEntry.value as Map).cast<String, dynamic>();
    for (final tableEntry in tables.entries) {
      final table = tableEntry.key;
      final loc = 'data_model.$schema.$table';
      if (tableEntry.value is! Map) {
        throw ContractError('$loc must be a mapping.');
      }
      final t = (tableEntry.value as Map).cast<String, dynamic>();
      _requireString(t, 'ownership', '$loc.ownership');
      _requirePrimaryKey(t, '$loc.primary_key');
      final kind = t['kind'];
      if (kind != null && kind != 'table' && kind != 'view') {
        throw ContractError(
            "$loc.kind is '$kind' but must be 'table' (default) or 'view'.");
      }
      if (t['fields'] is! Map) {
        throw ContractError(
            "$loc.fields is required and must be a mapping of column → type.");
      }
    }
  }

  _validateRpcFunctions(root);
}

const _rpcScalarReturns = {
  'uuid',
  'text',
  'integer',
  'boolean',
  'json',
  'void',
};

void _validateRpcFunctions(Map<String, dynamic> root) {
  final rpc = root['rpc_functions'];
  if (rpc == null) return;
  if (rpc is! Map) {
    throw ContractError(
        "'rpc_functions' must be a mapping of function name → config.");
  }
  final publicTables =
      ((root['data_model'] as Map<String, dynamic>)['public'] as Map?)
              ?.keys
              .map((k) => k.toString())
              .toSet() ??
          {};

  for (final entry in rpc.cast<String, dynamic>().entries) {
    if (entry.value is! Map) continue; // tolerate scalar keys
    final name = entry.key;
    final loc = 'rpc_functions.$name';
    final fn = (entry.value as Map).cast<String, dynamic>();

    final args = fn['args'];
    if (args != null && args is! Map) {
      throw ContractError('$loc.args must be a mapping of argument → type.');
    }
    final argNames =
        (args as Map?)?.keys.map((k) => k.toString()).toSet() ?? <String>{};

    final optional = fn['optional_args'];
    if (optional != null) {
      if (optional is! List) {
        throw ContractError('$loc.optional_args must be a list.');
      }
      for (final o in optional) {
        if (!argNames.contains(o.toString())) {
          throw ContractError(
              "$loc.optional_args contains '$o' which is not declared in $loc.args.");
        }
      }
    }

    final returns = fn['returns'];
    if (returns is! String || returns.isEmpty) {
      throw ContractError(
          '$loc.returns is required and must be one of: uuid | text | integer '
          '| boolean | json | void | row:<table> | rows:<table>.');
    }
    if (returns.startsWith('row:') || returns.startsWith('rows:')) {
      final table = returns.substring(returns.indexOf(':') + 1);
      if (!publicTables.contains(table)) {
        throw ContractError(
            "$loc.returns references table '$table' which is not declared in "
            'data_model.public.');
      }
    } else if (!_rpcScalarReturns.contains(returns)) {
      throw ContractError(
          "$loc.returns is '$returns' but must be one of: uuid | text | "
          'integer | boolean | json | void | row:<table> | rows:<table>.');
    }
  }
}

/// `primary_key` accepts a column name or a non-empty list of column names
/// (composite key), e.g. `primary_key: id` or `primary_key: [session_id, user_id]`.
void _requirePrimaryKey(Map<String, dynamic> table, String loc) {
  final v = table['primary_key'];
  if (v is String && v.isNotEmpty) return;
  if (v is List &&
      v.isNotEmpty &&
      v.every((e) => e is String && e.isNotEmpty)) {
    return;
  }
  throw ContractError(
      '$loc is required and must be a column name or a non-empty list of '
      'column names (composite key).');
}

void _requireMap(Map<String, dynamic> parent, String key) {
  if (parent[key] is! Map) {
    throw ContractError("'$key' section is required and must be a mapping.");
  }
}

void _requireString(Map<String, dynamic> parent, String key, String loc) {
  final v = parent[key];
  if (v is! String || v.isEmpty) {
    throw ContractError("$loc is required and must be a non-empty string.");
  }
}

/// Recursively converts YAML nodes to plain Dart maps/lists/scalars.
dynamic yamlToJson(dynamic node) {
  if (node is YamlMap) {
    return Map<String, dynamic>.fromEntries(
      node.entries.map((e) => MapEntry(e.key.toString(), yamlToJson(e.value))),
    );
  }
  if (node is YamlList) return node.map(yamlToJson).toList();
  return node;
}
