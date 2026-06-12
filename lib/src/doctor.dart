/// Best-practice linter for `supabase.yaml` contracts.
///
/// Two layers of rules:
/// - Contract-only rules (DR0xx) run on the raw YAML mapping, so they work
///   even on drafts the strict loader would reject.
/// - DB rules (DR1xx) compare the contract against a live [DbSchema] snapshot
///   and catch the classic killers: unmanaged RPCs, missing RLS,
///   SECURITY DEFINER functions without a pinned search_path.
///
/// Findings are deterministic: rules run in code order, entries in
/// alphabetical order — the same input always produces the same report.
library;

import 'db_schema.dart';

enum DoctorSeverity { error, warn, info }

class DoctorFinding {
  final String code;
  final DoctorSeverity severity;

  /// Contract path of the offending entry (e.g.
  /// `data_model.public.things.primary_key`) or a `db.` path for findings
  /// rooted in the database.
  final String path;
  final String message;
  final String fix;

  const DoctorFinding({
    required this.code,
    required this.severity,
    required this.path,
    required this.message,
    required this.fix,
  });

  Map<String, String> toJson() => {
        'code': code,
        'severity': severity.name,
        'path': path,
        'message': message,
        'fix': fix,
      };
}

/// Runs all contract-only rules (DR001–DR009) over the raw YAML mapping.
List<DoctorFinding> lintContract(Map<String, dynamic> raw) {
  final findings = <DoctorFinding>[];

  final dataModel = _asMap(raw['data_model']);
  for (final schema in dataModel.keys.toList()..sort()) {
    final tables = _asMap(dataModel[schema]);
    for (final tableName in tables.keys.toList()..sort()) {
      final table = _asMap(tables[tableName]);
      final loc = 'data_model.$schema.$tableName';
      final isView = table['kind'] == 'view';
      final fields = _asMap(table['fields']);

      // DR001 — table without a primary key.
      final pk = table['primary_key'];
      final pkColumns = pk is List
          ? pk.map((e) => e.toString()).toList()
          : pk is String && pk.isNotEmpty
              ? [pk]
              : <String>[];
      if (pkColumns.isEmpty) {
        findings.add(DoctorFinding(
          code: 'DR001',
          severity: DoctorSeverity.error,
          path: '$loc.primary_key',
          message: "Table '$tableName' declares no primary_key.",
          fix: 'Declare primary_key: <column> (or a list for composite '
              'keys) — update/delete/stream depend on it.',
        ));
      }

      // DR009 — primary key column(s) not present in fields.
      for (final col in pkColumns) {
        if (!fields.containsKey(col)) {
          findings.add(DoctorFinding(
            code: 'DR009',
            severity: DoctorSeverity.error,
            path: '$loc.primary_key',
            message:
                "primary_key column '$col' is not declared in $loc.fields.",
            fix: "Add '$col' to fields or correct the primary_key.",
          ));
        }
      }

      // DR002 — client_access missing entirely.
      if (table['client_access'] == null) {
        findings.add(DoctorFinding(
          code: 'DR002',
          severity: DoctorSeverity.warn,
          path: loc,
          message: "Table '$tableName' declares no client_access — the "
              'intended access model is undocumented.',
          fix: 'Declare client_access with select/insert/update/delete '
              '(use edge_function_only for server-managed writes).',
        ));
      }

      // DR003 — mutation access declared on a view.
      if (isView) {
        final access = _asMap(table['client_access']);
        final mutations = ['insert', 'update', 'delete']
            .where((op) => access.containsKey(op))
            .toList();
        if (mutations.isNotEmpty) {
          findings.add(DoctorFinding(
            code: 'DR003',
            severity: DoctorSeverity.warn,
            path: '$loc.client_access',
            message: "View '$tableName' declares ${mutations.join('/')} "
                'access, but views never get mutation methods.',
            fix: 'Remove the mutation entries from client_access — only '
                'select applies to a view.',
          ));
        }
      }

      // DR004 — declared enum not used by any field of this table.
      final enumValues = _asMap(table['enum_values']);
      for (final enumName in enumValues.keys.toList()..sort()) {
        final used = fields.values.any((t) => t == enumName);
        if (!used) {
          findings.add(DoctorFinding(
            code: 'DR004',
            severity: DoctorSeverity.warn,
            path: '$loc.enum_values.$enumName',
            message: "Enum '$enumName' is declared on '$tableName' but no "
                'field of this table uses it as a type.',
            fix: 'Type a field as $enumName, or move/remove the '
                'declaration (enums bind per table).',
          ));
        }
      }
    }
  }

  // DR005 — edge function without description.
  final edgeFunctions = _asMap(raw['edge_functions']);
  for (final name in edgeFunctions.keys.toList()..sort()) {
    final fn = edgeFunctions[name];
    if (fn is! Map) continue; // tolerate scalar keys such as runtime:
    final fnMap = fn.cast<String, dynamic>();
    if (fnMap['description'] == null && fnMap['purpose'] == null) {
      findings.add(DoctorFinding(
        code: 'DR005',
        severity: DoctorSeverity.info,
        path: 'edge_functions.$name',
        message: "Edge function '$name' has no description.",
        fix: 'Add description: — the contract is documentation; agents and '
            'humans read it.',
      ));
    }
  }

  // DR006 — RPC function without description.
  final rpcFunctions = _asMap(raw['rpc_functions']);
  for (final name in rpcFunctions.keys.toList()..sort()) {
    final fn = rpcFunctions[name];
    if (fn is! Map) continue;
    if (fn.cast<String, dynamic>()['description'] == null) {
      findings.add(DoctorFinding(
        code: 'DR006',
        severity: DoctorSeverity.info,
        path: 'rpc_functions.$name',
        message: "RPC function '$name' has no description.",
        fix: 'Add description: — the contract is documentation; agents and '
            'humans read it.',
      ));
    }
  }

  // DR007 — public storage bucket.
  final buckets = _asMap(_asMap(raw['storage'])['buckets']);
  for (final name in buckets.keys.toList()..sort()) {
    final bucket = _asMap(buckets[name]);
    if (bucket['public'] == true) {
      findings.add(DoctorFinding(
        code: 'DR007',
        severity: DoctorSeverity.warn,
        path: 'storage.buckets.$name',
        message: "Bucket '$name' is public — every object is readable (and "
            'listable via the API) by anyone with the URL.',
        fix: 'Confirm nothing sensitive lands here, or set public: false '
            'and serve signed URLs.',
      ));
    }
  }

  // DR008 — realtime event on a table that is not in the publication.
  final realtime = _asMap(raw['realtime']);
  final allowedTables = (_asMap(realtime['publication'])['allowed_tables']
              as List?)
          ?.map((e) => e.toString())
          .toSet() ??
      <String>{};
  final events = _asMap(realtime['events']);
  for (final eventName in events.keys.toList()..sort()) {
    final event = _asMap(events[eventName]);
    final source = event['source'];
    if (source is String &&
        source.contains('.') &&
        !allowedTables.contains(source)) {
      findings.add(DoctorFinding(
        code: 'DR008',
        severity: DoctorSeverity.error,
        path: 'realtime.events.$eventName',
        message: "Event '$eventName' sources '$source', but that table is "
            'not in realtime.publication.allowed_tables — the event will '
            'never fire.',
        fix: "Add '$source' to realtime.publication.allowed_tables (and to "
            'the supabase_realtime publication in the DB).',
      ));
    }
  }

  return findings;
}

/// Runs all DB-backed rules (DR101–DR106) comparing the contract against a
/// live schema snapshot.
List<DoctorFinding> lintAgainstDb(Map<String, dynamic> raw, DbSchema db) {
  final findings = <DoctorFinding>[];

  final publicModel = _asMap(_asMap(raw['data_model'])['public']);
  final contractTables = <String>{};
  final contractViews = <String>{};
  for (final entry in publicModel.entries) {
    final table = _asMap(publicModel[entry.key]);
    (table['kind'] == 'view' ? contractViews : contractTables).add(entry.key);
  }
  final contractRpc = <String>{
    for (final entry in _asMap(raw['rpc_functions']).entries)
      if (entry.value is Map) entry.key,
  };

  // DR101 — DB function not covered by the contract (unmanaged RPC).
  for (final name in db.functions.keys.toList()..sort()) {
    if (!contractRpc.contains(name)) {
      findings.add(DoctorFinding(
        code: 'DR101',
        severity: DoctorSeverity.warn,
        path: 'rpc_functions',
        message: "DB function 'public.$name' is not declared in the contract "
            '— an unmanaged RPC the contract knows nothing about.',
        fix: "Declare it under rpc_functions (init --from-db drafts it), or "
            'drop it from the database.',
      ));
    }
  }

  // DR102 — contract RPC missing in the DB.
  for (final name in contractRpc.toList()..sort()) {
    if (!db.functions.containsKey(name)) {
      findings.add(DoctorFinding(
        code: 'DR102',
        severity: DoctorSeverity.error,
        path: 'rpc_functions.$name',
        message: "RPC function '$name' is declared in the contract but does "
            'not exist in the database — calls will fail at runtime.',
        fix: 'Create the function via a migration, or remove it from the '
            'contract.',
      ));
    }
  }

  // DR103 — SECURITY DEFINER function without pinned search_path.
  for (final name in db.functions.keys.toList()..sort()) {
    final fn = db.functions[name]!;
    if (fn.isSecurityDefiner && !fn.hasSearchPath) {
      findings.add(DoctorFinding(
        code: 'DR103',
        severity: DoctorSeverity.warn,
        path: 'db.functions.$name',
        message: "Function 'public.$name' is SECURITY DEFINER without a "
            'pinned search_path — a classic privilege-escalation vector.',
        fix: 'ALTER FUNCTION public.$name SET search_path = \'\'; (or list '
            'the schemas it needs).',
      ));
    }
  }

  // DR104 — SECURITY DEFINER view (no security_invoker).
  for (final name in db.securityDefinerViews.toList()..sort()) {
    findings.add(DoctorFinding(
      code: 'DR104',
      severity: DoctorSeverity.warn,
      path: 'db.views.$name',
      message: "View 'public.$name' runs with the owner's privileges "
          '(security_invoker is not set) — it can bypass RLS.',
      fix: 'ALTER VIEW public.$name SET (security_invoker = true); then '
          'verify the view still returns what clients expect.',
    ));
  }

  // DR105 — DB table not covered by the contract.
  for (final name in db.tables.keys.toList()..sort()) {
    if (!contractTables.contains(name) && !contractViews.contains(name)) {
      findings.add(DoctorFinding(
        code: 'DR105',
        severity: DoctorSeverity.info,
        path: 'data_model.public',
        message: "DB table 'public.$name' is not declared in the contract.",
        fix: 'Intentional (server-only table)? Fine. Otherwise draft it with '
            'init --from-db.',
      ));
    }
  }

  // DR106 — RLS not enabled on a contract-covered table.
  for (final name in contractTables.toList()..sort()) {
    if (db.rlsEnabled[name] == false) {
      findings.add(DoctorFinding(
        code: 'DR106',
        severity: DoctorSeverity.error,
        path: 'data_model.public.$name',
        message: "Table 'public.$name' is client-facing per the contract but "
            'has row-level security DISABLED in the database.',
        fix: 'ALTER TABLE public.$name ENABLE ROW LEVEL SECURITY; and add '
            'policies matching client_access.',
      ));
    }
  }

  return findings;
}

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? value.cast<String, dynamic>() : const {};
