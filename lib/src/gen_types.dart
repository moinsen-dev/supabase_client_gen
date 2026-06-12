import 'dart:io';

/// Supabase gen-types integration and migration-awareness checks.

/// Parsed representation of a `supabase gen types --local` TypeScript output.
class GenTypes {
  final Set<String> tableNames;
  final Map<String, Set<String>> tableColumns;
  final Map<String, Map<String, bool>> columnNullability;
  final Set<String> enumNames;

  /// Names of Postgres functions in the `public.Functions` scope — the DB-side
  /// truth that contract-declared `rpc_functions` are checked against.
  final Set<String> functionNames;

  /// Names of views in the `public.Views` scope — the DB-side truth that
  /// contract entries declared `kind: view` are checked against.
  final Set<String> viewNames;

  /// Raw TypeScript type per table `Row` member (e.g. `string | null`,
  /// `Database["public"]["Enums"]["mood"]`). Backs `init --from-gen-types`.
  final Map<String, Map<String, String>> rowTypes;

  /// Columns per view (from the view's `Row` block).
  final Map<String, Set<String>> viewColumns;

  /// Raw TypeScript type per view `Row` member.
  final Map<String, Map<String, String>> viewRowTypes;

  /// Enum name → string literal values from the `Enums` scope.
  final Map<String, List<String>> enumValues;

  const GenTypes({
    required this.tableNames,
    required this.tableColumns,
    required this.columnNullability,
    required this.enumNames,
    this.functionNames = const {},
    this.viewNames = const {},
    this.rowTypes = const {},
    this.viewColumns = const {},
    this.viewRowTypes = const {},
    this.enumValues = const {},
  });

  factory GenTypes.parse(String ts) {
    final tableNames = <String>{};
    final tableColumns = <String, Set<String>>{};
    final columnNullability = <String, Map<String, bool>>{};
    final enumNames = <String>{};
    final functionNames = <String>{};
    final viewNames = <String>{};
    final rowTypes = <String, Map<String, String>>{};
    final viewColumns = <String, Set<String>>{};
    final viewRowTypes = <String, Map<String, String>>{};
    final enumValues = <String, List<String>>{};
    String? currentEnum;

    final lines = ts.split('\n');

    // Brace depth (incremented on every line)
    var depth = 0;
    void count(String s) {
      for (var i = 0; i < s.length; i++) {
        if (s[i] == '{' || s[i] == '[') depth++;
        if (s[i] == '}' || s[i] == ']') depth--;
      }
    }

    // State machine: wait → inPublic → inScope('tables'|'views'|'functions'|'enums')
    var state = 'wait';
    var scopeDepth = 0; // depth when current scope started
    var inSubBlock = false; // inside Row/Insert/Update
    String? subBlockName; // which of Row/Insert/Update we are in
    var inRelationships = false;
    var relDepth = 0; // depth when Relationships started
    String? currentTable;
    String? currentView;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();
      final depthBefore = depth; // depth at the start of this line
      count(trimmed);

      switch (state) {
        case 'wait':
          if (trimmed == 'public: {' || trimmed == 'public:') {
            state = 'inPublic';
            scopeDepth = depth - 1;
          }
          break;

        case 'inPublic':
          // Enter a scope
          if (_scopeMatch(trimmed, 'Tables')) {
            state = 'tables';
            scopeDepth = depth - 1;
            break;
          }
          if (_scopeMatch(trimmed, 'Views')) {
            state = 'views';
            scopeDepth = depth - 1;
            break;
          }
          if (_scopeMatch(trimmed, 'Functions')) {
            state = 'functions';
            scopeDepth = depth - 1;
            break;
          }
          if (_scopeMatch(trimmed, 'Enums')) {
            state = 'enums';
            scopeDepth = depth - 1;
            break;
          }
          if (_scopeMatch(trimmed, 'CompositeTypes')) {
            state = 'enums';
            scopeDepth = depth - 1;
            break;
          }
          // Exit public
          if (depth <= scopeDepth) state = 'wait';
          break;

        case 'tables':
          if (depth <= scopeDepth) {
            state = 'inPublic';
            break;
          }

          // Relationships tracking
          if (inRelationships) {
            if (depth <= relDepth) inRelationships = false;
            break;
          }

          // Enter sub-block
          final subMatch = RegExp(r'^(Row|Insert|Update):').firstMatch(trimmed);
          if (!inSubBlock && subMatch != null) {
            inSubBlock = true;
            subBlockName = subMatch.group(1);
            break;
          }

          // Exit sub-block
          if (inSubBlock && trimmed == '}') {
            inSubBlock = false;
            subBlockName = null;
            break;
          }

          // Table detection (only outside sub-blocks and relationships)
          if (!inSubBlock && !inRelationships) {
            if (trimmed == 'Relationships: [' ||
                trimmed.startsWith('Relationships:')) {
              inRelationships = true;
              relDepth = depth - 1; // depth after [ counted
              break;
            }
            final tableMatch = RegExp(r'^(\w+):').firstMatch(trimmed);
            if (tableMatch != null &&
                !{
                  'Row',
                  'Insert',
                  'Update',
                  'Relationships',
                  'Views',
                  'Functions',
                  'Enums',
                  'CompositeTypes'
                }.contains(tableMatch.group(1))) {
              final table = tableMatch.group(1)!;
              currentTable = table;
              tableNames.add(table);
              tableColumns[table] = {};
              columnNullability[table] = {};
              rowTypes[table] = {};
              break;
            }
          }

          // Column detection within sub-blocks
          if (inSubBlock && currentTable != null) {
            final colMatch = RegExp(r'^(\w+)(\??):').firstMatch(trimmed);
            if (colMatch != null &&
                !{'Row', 'Insert', 'Update', 'Relationships'}
                    .contains(colMatch.group(1))) {
              final colName = colMatch.group(1)!;
              final nullable = colMatch.group(2) == '?';
              tableColumns[currentTable]!.add(colName);
              columnNullability[currentTable]![colName] = nullable;
              if (subBlockName == 'Row') {
                rowTypes[currentTable]![colName] =
                    trimmed.substring(trimmed.indexOf(':') + 1).trim();
              }
            }
          }
          break;

        case 'views':
          if (depth <= scopeDepth) {
            state = 'inPublic';
            break;
          }
          // View names sit directly under the Views scope; their Row members
          // live one level deeper.
          if (depthBefore == scopeDepth + 1) {
            final viewMatch = RegExp(r'^(\w+)\??:').firstMatch(trimmed);
            if (viewMatch != null) {
              currentView = viewMatch.group(1)!;
              viewNames.add(currentView);
              viewColumns[currentView] = {};
              viewRowTypes[currentView] = {};
              inSubBlock = false;
              subBlockName = null;
            }
            break;
          }
          // Row members of the current view (Insert/Update never exist on
          // read-only views; updatable views may carry them — only Row counts).
          {
            final subMatch =
                RegExp(r'^(Row|Insert|Update):').firstMatch(trimmed);
            if (!inSubBlock && subMatch != null) {
              inSubBlock = true;
              subBlockName = subMatch.group(1);
              break;
            }
            if (inSubBlock && trimmed == '}') {
              inSubBlock = false;
              subBlockName = null;
              break;
            }
            if (inSubBlock && subBlockName == 'Row' && currentView != null) {
              final colMatch = RegExp(r'^(\w+)(\??):').firstMatch(trimmed);
              if (colMatch != null) {
                final colName = colMatch.group(1)!;
                viewColumns[currentView]!.add(colName);
                viewRowTypes[currentView]![colName] =
                    trimmed.substring(trimmed.indexOf(':') + 1).trim();
              }
            }
          }
          break;

        case 'functions':
          if (depth <= scopeDepth) {
            state = 'inPublic';
            break;
          }
          // Function names sit directly under the Functions scope; their
          // Args/Returns members live one level deeper.
          if (depthBefore == scopeDepth + 1) {
            final fnMatch = RegExp(r'^(\w+)\??:').firstMatch(trimmed);
            if (fnMatch != null) functionNames.add(fnMatch.group(1)!);
          }
          break;

        case 'enums':
          if (depth <= scopeDepth) {
            state = 'inPublic';
            break;
          }
          final enumMatch = RegExp(r'^(\w+):').firstMatch(trimmed);
          if (enumMatch != null && enumMatch.group(1) != 'schema') {
            final enumName = enumMatch.group(1)!;
            enumNames.add(enumName);
            currentEnum = enumName;
            enumValues[enumName] = _enumLiterals(
              trimmed.substring(trimmed.indexOf(':') + 1),
            );
          } else if (currentEnum != null && trimmed.startsWith('|')) {
            // Multi-line union continuation: `| "value"`.
            enumValues[currentEnum]!.addAll(_enumLiterals(trimmed));
          }
          break;
      }
    }

    return GenTypes(
      tableNames: tableNames,
      tableColumns: tableColumns,
      columnNullability: columnNullability,
      enumNames: enumNames,
      functionNames: functionNames,
      viewNames: viewNames,
      rowTypes: rowTypes,
      viewColumns: viewColumns,
      viewRowTypes: viewRowTypes,
      enumValues: enumValues,
    );
  }

  static bool _scopeMatch(String trimmed, String name) =>
      trimmed == '$name: {' || trimmed == '$name:';

  /// Extracts double-quoted string literals from a TS union type fragment,
  /// e.g. `"happy" | "sad"` → `[happy, sad]`.
  static List<String> _enumLiterals(String fragment) => RegExp(r'"([^"]*)"')
      .allMatches(fragment)
      .map((m) => m.group(1)!)
      .toList();
}

/// Checks for migrations that postdate the contract.
class MigrationCheck {
  final String? latestMigration;
  final String contractDate;
  final bool migrationNewer;

  const MigrationCheck({
    required this.latestMigration,
    required this.contractDate,
    required this.migrationNewer,
  });

  factory MigrationCheck.check(String migrationsDir, String contractDate) {
    final dir = Directory(migrationsDir);
    if (!dir.existsSync()) {
      return MigrationCheck(
          latestMigration: null,
          contractDate: contractDate,
          migrationNewer: false);
    }

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sql'))
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    final latest = files.isNotEmpty ? files.first.path.split('/').last : null;

    if (latest == null) {
      return MigrationCheck(
          latestMigration: null,
          contractDate: contractDate,
          migrationNewer: false);
    }

    final migrationDate = latest.substring(0, 8);
    final migrationNewer =
        migrationDate.compareTo(contractDate.replaceAll('-', '')) > 0;

    return MigrationCheck(
        latestMigration: latest,
        contractDate: contractDate,
        migrationNewer: migrationNewer);
  }
}
