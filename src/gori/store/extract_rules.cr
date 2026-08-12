require "db"

module Gori
  class Store
    # --- extract rules (the READ half of a session binding, #501) ------------
    #
    # Unordered on purpose (`ORDER BY name` is for display alone): an extract rule
    # produces no bytes, so two of them cannot compose and there is nothing to order.
    # Contrast `match_rules`, which is ordered by `position` because two rewrite rules
    # genuinely do compose on the same bytes.

    def extract_rules : Array(ExtractRule)
      list = [] of ExtractRule
      @db.query("SELECT id, enabled, name, match_filter, kind, selector, pos_start, pos_end, host FROM extract_rules ORDER BY name, id") do |rs|
        rs.each do
          id = rs.read(Int64)
          enabled = rs.read(Int32) != 0
          name = rs.read(String)
          filter = rs.read(String)
          kind = Gori::ExtractKind.parse?(rs.read(String)) || Gori::ExtractKind::Cookie
          list << ExtractRule.new(id, enabled, name, filter, kind,
            rs.read(String), rs.read(Int32), rs.read(Int32), rs.read(String))
        end
      end
      list
    end

    # Returns the new row id, or 0 when the write was dropped (store busy/closing) — the
    # same contract `insert_issue` has. A duplicate `name` violates the UNIQUE index and
    # is a dropped write here; `Bindings#validate` refuses it with a message first, so
    # this is the backstop rather than the operator-facing error.
    def insert_extract_rule(name : String, match_filter : String, kind : Gori::ExtractKind,
                            selector : String = "", pos_start : Int32 = 0, pos_end : Int32 = 0,
                            host : String = "", enabled : Bool = true) : Int64
      exec_task ->(c : DB::Connection) {
        # OR IGNORE: a duplicate `name` is a dropped write by design (see above), and a RAISE
        # here would roll back the whole writer batch and poison the connection's cached
        # statement until teardown — see `update_scope_rule` for what that cost.
        c.exec("INSERT OR IGNORE INTO extract_rules (enabled, name, match_filter, kind, selector, pos_start, pos_end, host) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          enabled ? 1 : 0, name, match_filter, kind.label, selector, pos_start, pos_end, host)
        nil
      }
    end

    # Returns whether the write committed (false = store busy/locked/closing).
    def update_extract_rule(id : Int64, name : String, match_filter : String, kind : Gori::ExtractKind,
                            selector : String = "", pos_start : Int32 = 0, pos_end : Int32 = 0,
                            host : String = "") : Bool
      changed = 0_i64
      ok = exec_task_ok ->(c : DB::Connection) {
        # OR IGNORE + changes(), like `update_scope_rule`: renaming onto another rule's UNIQUE
        # `name` must not raise inside the writer's transaction.
        c.exec("UPDATE OR IGNORE extract_rules SET name = ?, match_filter = ?, kind = ?, selector = ?, pos_start = ?, pos_end = ?, host = ? WHERE id = ?",
          name, match_filter, kind.label, selector, pos_start, pos_end, host, id)
        changed = c.scalar("SELECT changes()").as(Int64)
        nil
      }
      ok && changed > 0
    end

    def set_extract_rule_enabled(id : Int64, enabled : Bool) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("UPDATE extract_rules SET enabled = ? WHERE id = ?", enabled ? 1 : 0, id); nil }
    end

    def delete_extract_rule(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("DELETE FROM extract_rules WHERE id = ?", id); nil }
    end
  end
end
