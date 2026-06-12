/// Parsed representation of docs/contracts/supabase.yaml.
library;

class SupabaseContract {
  final ContractMeta contract;
  final ProjectMeta project;
  final AuthConfig auth;
  final Map<String, RoleConfig> roles;
  final Map<String, SchemaConfig> schemas;
  final Map<String, Map<String, TableConfig>> dataModel;
  final StorageConfig? storage;
  final Map<String, EdgeFunctionConfig>? edgeFunctions;
  final Map<String, RpcFunctionConfig>? rpcFunctions;
  final RealtimeConfig? realtime;

  const SupabaseContract({
    required this.contract,
    required this.project,
    required this.auth,
    required this.roles,
    required this.schemas,
    required this.dataModel,
    this.storage,
    this.edgeFunctions,
    this.rpcFunctions,
    this.realtime,
  });

  factory SupabaseContract.fromYaml(Map<String, dynamic> yaml) {
    return SupabaseContract(
      contract: ContractMeta.fromYaml(yaml['contract'] as Map<String, dynamic>),
      project: ProjectMeta.fromYaml(yaml['project'] as Map<String, dynamic>),
      auth: AuthConfig.fromYaml(yaml['auth'] as Map<String, dynamic>),
      roles: _parseRoles(yaml['roles'] as Map<String, dynamic>?),
      schemas: _parseSchemas(yaml['schemas'] as Map<String, dynamic>? ?? {}),
      dataModel: _parseDataModel(
        yaml['data_model'] as Map<String, dynamic>? ?? {},
      ),
      storage: yaml['storage'] != null
          ? StorageConfig.fromYaml(yaml['storage'] as Map<String, dynamic>)
          : null,
      edgeFunctions: yaml['edge_functions'] != null
          ? _parseEdgeFunctions(yaml['edge_functions'] as Map<String, dynamic>)
          : null,
      rpcFunctions: yaml['rpc_functions'] != null
          ? _parseRpcFunctions(yaml['rpc_functions'] as Map<String, dynamic>)
          : null,
      realtime: yaml['realtime'] != null
          ? RealtimeConfig.fromYaml(yaml['realtime'] as Map<String, dynamic>)
          : null,
    );
  }

  /// Parses edge-function entries, skipping non-mapping keys such as the
  /// conventional `runtime:` scalar that lives alongside the function configs.
  static Map<String, EdgeFunctionConfig> _parseEdgeFunctions(
    Map<String, dynamic> yaml,
  ) {
    final result = <String, EdgeFunctionConfig>{};
    for (final entry in yaml.entries) {
      if (entry.value is! Map) continue;
      result[entry.key] = EdgeFunctionConfig.fromYaml(
        (entry.value as Map).cast<String, dynamic>(),
      );
    }
    return result;
  }

  /// Parses rpc-function entries, skipping non-mapping keys (mirrors the
  /// tolerance for scalar keys under `edge_functions`).
  static Map<String, RpcFunctionConfig> _parseRpcFunctions(
    Map<String, dynamic> yaml,
  ) {
    final result = <String, RpcFunctionConfig>{};
    for (final entry in yaml.entries) {
      if (entry.value is! Map) continue;
      result[entry.key] = RpcFunctionConfig.fromYaml(
        (entry.value as Map).cast<String, dynamic>(),
      );
    }
    return result;
  }

  static Map<String, RoleConfig> _parseRoles(Map<String, dynamic>? yaml) {
    if (yaml == null) return {};
    final roles = yaml['workspace_roles'] as Map<String, dynamic>?;
    if (roles == null) return {};
    return roles.map(
      (k, v) => MapEntry(k, RoleConfig.fromYaml(v as Map<String, dynamic>)),
    );
  }

  static Map<String, SchemaConfig> _parseSchemas(Map<String, dynamic> yaml) {
    return yaml.map(
      (k, v) => MapEntry(k, SchemaConfig.fromYaml(v as Map<String, dynamic>)),
    );
  }

  static Map<String, Map<String, TableConfig>> _parseDataModel(
    Map<String, dynamic> yaml,
  ) {
    final result = <String, Map<String, TableConfig>>{};
    for (final entry in yaml.entries) {
      final schemaName = entry.key;
      final tables = entry.value as Map<String, dynamic>;
      result[schemaName] = tables.map(
        (k, v) => MapEntry(k, TableConfig.fromYaml(v as Map<String, dynamic>)),
      );
    }
    return result;
  }

  Map<String, TableConfig> get publicTables => dataModel['public'] ?? {};

  /// Public tables that have Realtime enabled (from contract `realtime.publication.allowed_tables`).
  Set<String> get realtimePublicTables {
    if (realtime == null) return {};
    return realtime!.allowedTables
        .where((t) => t.startsWith('public.'))
        .map((t) => t.substring(7)) // strip "public." prefix
        .toSet();
  }
}

class ContractMeta {
  final String name;
  final String version;
  final String date;
  const ContractMeta({
    required this.name,
    required this.version,
    required this.date,
  });
  factory ContractMeta.fromYaml(Map<String, dynamic> yaml) => ContractMeta(
        name: yaml['name'] as String,
        version: yaml['version'] as String,
        date: yaml['date'] as String,
      );
}

class ProjectMeta {
  final String remoteName;
  final String remoteRef;
  const ProjectMeta({required this.remoteName, required this.remoteRef});
  factory ProjectMeta.fromYaml(Map<String, dynamic> yaml) {
    final remote = yaml['remote'] as Map<String, dynamic>;
    return ProjectMeta(
      remoteName: remote['name'] as String,
      remoteRef: remote['ref'] as String,
    );
  }
}

class AuthConfig {
  final String provider;
  final List<String> signInMethods;
  const AuthConfig({required this.provider, required this.signInMethods});
  factory AuthConfig.fromYaml(Map<String, dynamic> yaml) => AuthConfig(
        provider: yaml['provider'] as String,
        signInMethods: (yaml['planned_sign_in_methods'] as List).cast<String>(),
      );
}

class RoleConfig {
  final String description;
  const RoleConfig({required this.description});
  factory RoleConfig.fromYaml(Map<String, dynamic> yaml) =>
      RoleConfig(description: yaml['description'] as String);
}

class SchemaConfig {
  final bool exposedToDataApi;
  final String purpose;
  const SchemaConfig({required this.exposedToDataApi, required this.purpose});
  factory SchemaConfig.fromYaml(Map<String, dynamic> yaml) => SchemaConfig(
        exposedToDataApi: yaml['exposed_to_data_api'] as bool,
        purpose: yaml['purpose'] as String,
      );
}

class TableConfig {
  final String ownership;
  final String primaryKey;
  final Map<String, String> fields;
  final Map<String, List<String>>? enumValues;
  final Map<String, String>? clientAccess;
  final List<String>? unique;
  final String? description;
  final List<String>? nullableFields;

  const TableConfig({
    required this.ownership,
    required this.primaryKey,
    required this.fields,
    this.enumValues,
    this.clientAccess,
    this.unique,
    this.description,
    this.nullableFields,
  });

  factory TableConfig.fromYaml(Map<String, dynamic> yaml) => TableConfig(
        ownership: yaml['ownership'] as String,
        primaryKey: yaml['primary_key'] as String,
        fields: (yaml['fields'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, v as String),
        ),
        enumValues: yaml['enum_values'] != null
            ? (yaml['enum_values'] as Map<String, dynamic>).map(
                (k, v) => MapEntry(k, (v as List).cast<String>()),
              )
            : null,
        clientAccess: yaml['client_access'] != null
            ? (yaml['client_access'] as Map<String, dynamic>).map(
                (k, v) => MapEntry(k, v as String),
              )
            : null,
        unique: yaml['unique'] != null
            ? (yaml['unique'] as List).cast<String>()
            : null,
        nullableFields: yaml['nullable_fields'] != null
            ? (yaml['nullable_fields'] as List).cast<String>()
            : null,
        description: yaml['description'] as String?,
      );

  bool isEnumField(String fieldName) {
    if (enumValues == null) return false;
    final pgType = fields[fieldName];
    return pgType != null && enumValues!.containsKey(pgType);
  }

  String dartType(String fieldName) {
    final pgType = fields[fieldName] ?? 'text';
    return _mapPgType(pgType);
  }

  String _mapPgType(String pgType) {
    final scalar = tryMapPgScalarType(pgType);
    if (scalar != null) return scalar;
    if (enumValues != null && enumValues!.containsKey(pgType)) {
      return _toPascalCase(pgType);
    }
    return 'String';
  }

  String _toPascalCase(String snakeCase) => snakeCase
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join();
}

/// Maps a Postgres scalar type to its Dart type, or null when the type is not
/// a recognised scalar (e.g. a contract-declared enum). Shared by model fields
/// and RPC argument typing so both projections agree on the mapping.
String? tryMapPgScalarType(String pgType) {
  if (pgType == 'uuid') return 'String';
  if (pgType == 'text') return 'String';
  if (pgType == 'integer' || pgType == 'int4') return 'int';
  if (pgType == 'bigint' || pgType == 'int8') return 'int';
  if (pgType == 'numeric' || pgType == 'decimal') return 'double';
  if (pgType == 'boolean' || pgType == 'bool') return 'bool';
  if (pgType == 'timestamptz' || pgType == 'timestamp') return 'DateTime';
  if (pgType == 'date') return 'DateTime';
  if (pgType == 'jsonb' || pgType == 'json') return 'Map<String, dynamic>';
  if (pgType.startsWith('vector')) return 'List<double>';
  if (pgType == 'text[]' || pgType == '_text') return 'List<String>';
  return null;
}

class StorageConfig {
  final Map<String, StorageBucket> buckets;
  const StorageConfig({required this.buckets});
  factory StorageConfig.fromYaml(Map<String, dynamic> yaml) {
    final buckets = (yaml['buckets'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, StorageBucket.fromYaml(v as Map<String, dynamic>)),
    );
    return StorageConfig(buckets: buckets ?? {});
  }
}

class StorageBucket {
  final bool public;
  final List<String> allowedMimeTypes;
  final int? fileSizeLimitMb;
  const StorageBucket({
    required this.public,
    required this.allowedMimeTypes,
    this.fileSizeLimitMb,
  });
  factory StorageBucket.fromYaml(Map<String, dynamic> yaml) => StorageBucket(
        public: yaml['public'] as bool? ?? false,
        allowedMimeTypes:
            (yaml['allowed_mime_types'] as List?)?.cast<String>() ?? [],
        fileSizeLimitMb: yaml['file_size_limit_mb'] as int?,
      );
}

class EdgeFunctionConfig {
  final String method;
  final Map<String, String>? request;
  final Map<String, String>? response;
  final String? description;
  final List<String> requiredFields;
  final List<String> optionalFields;

  const EdgeFunctionConfig({
    required this.method,
    this.request,
    this.response,
    this.description,
    this.requiredFields = const [],
    this.optionalFields = const [],
  });

  factory EdgeFunctionConfig.fromYaml(Map<String, dynamic> yaml) =>
      EdgeFunctionConfig(
        method: yaml['method'] as String? ?? 'POST',
        request: yaml['request'] != null
            ? (yaml['request'] as Map<String, dynamic>).map(
                (k, v) => MapEntry(k, v as String),
              )
            : null,
        response: yaml['response'] != null
            ? (yaml['response'] as Map<String, dynamic>).map(
                (k, v) => MapEntry(k, v as String),
              )
            : null,
        description:
            yaml['description'] as String? ?? yaml['purpose'] as String?,
        requiredFields: _parseStringList(yaml, 'required_request_fields'),
        optionalFields: _parseStringList(yaml, 'optional_request_fields'),
      );

  static List<String> _parseStringList(Map<String, dynamic> yaml, String key) {
    final val = yaml[key];
    if (val is List) return val.cast<String>();
    return [];
  }
}

/// A Postgres function exposed to clients via `client.rpc(...)`.
///
/// Declared under the top-level `rpc_functions:` section of the contract:
///
/// ```yaml
/// rpc_functions:
///   get_vote_tally:
///     description: Tally votes for a song in a session.
///     args: { session_uuid: uuid, song_uuid: uuid }
///     returns: json
/// ```
class RpcFunctionConfig {
  /// Ordered argument name → Postgres type (same type names as table fields).
  final Map<String, String> args;

  /// Subset of [args] that are optional/nullable — omitted from the RPC call
  /// when null, so Postgres `DEFAULT` argument values still apply.
  final List<String> optionalArgs;

  /// One of `uuid | text | integer | boolean | json | void` or
  /// `row:<table>` / `rows:<table>` referencing a `data_model.public` table.
  final String returns;

  final String? description;

  const RpcFunctionConfig({
    required this.args,
    this.optionalArgs = const [],
    required this.returns,
    this.description,
  });

  factory RpcFunctionConfig.fromYaml(Map<String, dynamic> yaml) =>
      RpcFunctionConfig(
        args: yaml['args'] != null
            ? (yaml['args'] as Map<String, dynamic>).map(
                (k, v) => MapEntry(k, v as String),
              )
            : const {},
        optionalArgs: yaml['optional_args'] != null
            ? (yaml['optional_args'] as List).cast<String>()
            : const [],
        returns: yaml['returns'] as String,
        description: yaml['description'] as String?,
      );
}

class RealtimeConfig {
  final List<String> allowedTables;
  final List<String> replicaIdentityFull;
  final List<RealtimeEvent> events;

  const RealtimeConfig({
    required this.allowedTables,
    required this.replicaIdentityFull,
    required this.events,
  });

  factory RealtimeConfig.fromYaml(Map<String, dynamic> yaml) {
    final pub = yaml['publication'] as Map<String, dynamic>?;
    final events = (yaml['events'] as Map<String, dynamic>?)?.entries.map((e) {
      final ev = e.value as Map<String, dynamic>;
      return RealtimeEvent(
        name: e.key,
        source: ev['source'] as String,
        audience: ev['audience'] as String,
      );
    }).toList();
    return RealtimeConfig(
      allowedTables: (pub?['allowed_tables'] as List?)?.cast<String>() ?? [],
      replicaIdentityFull:
          (pub?['replica_identity_full'] as List?)?.cast<String>() ?? [],
      events: events ?? [],
    );
  }
}

class RealtimeEvent {
  final String name;
  final String source;
  final String audience;
  const RealtimeEvent({
    required this.name,
    required this.source,
    required this.audience,
  });
}
