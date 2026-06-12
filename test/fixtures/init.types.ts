export type Database = {
  public: {
    Tables: {
      sessions: {
        Row: {
          id: string
          code: string
          status: Database["public"]["Enums"]["session_status"]
          settings: Json
          started_at: string | null
          max_players: number
          is_open: boolean
        }
        Insert: {
          id?: string
          code: string
          status?: Database["public"]["Enums"]["session_status"]
          settings?: Json
          started_at?: string | null
          max_players?: number
          is_open?: boolean
        }
        Update: {
          id?: string
          code?: string
          status?: Database["public"]["Enums"]["session_status"]
          settings?: Json
          started_at?: string | null
          max_players?: number
          is_open?: boolean
        }
        Relationships: []
      }
      workspace_notes: {
        Row: {
          id: string
          workspace_id: string
          body: string | null
          tags: string[] | null
        }
        Insert: {
          id?: string
          workspace_id: string
          body?: string | null
          tags?: string[] | null
        }
        Update: {
          id?: string
          workspace_id?: string
          body?: string | null
          tags?: string[] | null
        }
        Relationships: [
          {
            foreignKeyName: "workspace_notes_workspace_id_fkey"
            columns: ["workspace_id"]
            isOneToOne: false
            referencedRelation: "workspaces"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      session_overview: {
        Row: {
          id: string | null
          code: string | null
          player_count: number | null
        }
        Relationships: []
      }
    }
    Functions: {
      get_session_by_code: {
        Args: {
          p_code: string
        }
        Returns: Json
      }
      heartbeat: {
        Args: Record<PropertyKey, never>
        Returns: boolean
      }
    }
    Enums: {
      session_status:
        | "lobby"
        | "active"
        | "ended"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}
