import 'package:supabase_client_gen/src/gen_types.dart';
import 'package:test/test.dart';

/// Parsing of `supabase gen types` TypeScript output, focused on the
/// Functions scope that backs the contract↔DB RPC drift check.
const _ts = '''
export type Database = {
  public: {
    Tables: {
      sessions: {
        Row: {
          id: string
          code: string
        }
        Insert: {
          id?: string
          code: string
        }
        Update: {
          id?: string
          code?: string
        }
        Relationships: []
      }
    }
    Views: {
      session_queue_overview: {
        Row: {
          id: string | null
          title: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      add_song_to_player_queue: {
        Args: {
          p_session_id: string
          p_title: string
        }
        Returns: string
      }
      get_vote_tally: {
        Args: {
          session_uuid: string
          song_uuid: string
        }
        Returns: Json
      }
      heartbeat: {
        Args: Record<PropertyKey, never>
        Returns: boolean
      }
    }
    Enums: {
      mood: "happy" | "sad"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}
''';

void main() {
  final genTypes = GenTypes.parse(_ts);

  test('collects function names from the Functions scope', () {
    expect(
      genTypes.functionNames,
      equals({'add_song_to_player_queue', 'get_vote_tally', 'heartbeat'}),
    );
  });

  test('function args are not mistaken for tables or columns', () {
    expect(genTypes.tableNames, equals({'sessions'}));
    expect(genTypes.tableColumns['sessions'], equals({'id', 'code'}));
    expect(genTypes.tableNames, isNot(contains('p_session_id')));
  });

  test('enums still parse alongside the Functions scope', () {
    expect(genTypes.enumNames, contains('mood'));
  });

  test('collects view names from the Views scope, not as tables', () {
    expect(genTypes.viewNames, equals({'session_queue_overview'}));
    expect(genTypes.tableNames, isNot(contains('session_queue_overview')));
    // Row members of a view are not mistaken for views.
    expect(genTypes.viewNames, isNot(contains('id')));
  });

  test('a types file without functions yields an empty set', () {
    final none = GenTypes.parse('''
export type Database = {
  public: {
    Tables: {
      things: {
        Row: {
          id: string
        }
      }
    }
    Functions: {
      [_ in never]: never
    }
  }
}
''');
    expect(none.functionNames, isEmpty);
    expect(none.viewNames, isEmpty);
    expect(none.tableNames, equals({'things'}));
  });
}
