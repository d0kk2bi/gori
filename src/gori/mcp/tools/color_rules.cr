require "json"
require "../../store"
require "../../colormarker"

module Gori
  module MCP
    class Tools
      # --- Colormarker rules (History row colouring) -----------------------------------
      #
      # DISPLAY ONLY: a colour rule never modifies traffic. Same two-scope model and the same
      # `{id, scope}` identity the Match & Replace tools above use, so an agent that learned
      # one has learned the other — with one axis genuinely different, and every description
      # says so: rewrite rules COMPOSE, colour rules RESOLVE (the first enabled match paints the
      # row and the rest are never consulted). That is why `move_color_rule` exists here where
      # the rewrite tools have no reorder: order is this rule set's meaning, not a tiebreak.

      # Every colour rule that applies to this project, in PRECEDENCE order: the global library
      # first, then the project's own rows.
      private def list_color_rules(h) : Result
        want = nil.as(Store::RuleScope?)
        if present?(h, "scope")
          sc = color_rule_scope(h)
          return sc if sc.is_a?(Result)
          want = sc
        end
        rules = Gori::Colormarker.merged(store)
        rules = rules.select { |r| r.scope == want } if want
        Result.new(JSON.build do |j|
          j.object do
            j.field "count", rules.size
            j.field "rules" do
              j.array do
                rules.each do |r|
                  j.object do
                    j.field "id", r.id
                    j.field "scope", r.scope.label
                    # The EFFECTIVE state here. For a global rule the library's own default may
                    # differ — this project overrode it — and both are reported so an agent can
                    # tell "off everywhere" from "off in this engagement".
                    j.field "enabled", r.enabled?
                    if r.global?
                      j.field "overridden", r.overridden?
                      j.field "default_enabled", Settings.colormarker_rules.find { |g| g.id == r.id }.try(&.enabled)
                    end
                    j.field "name", r.name
                    j.field "when", r.match_filter
                    j.field "color", r.color.label
                    j.field "style", r.style.label
                  end
                end
              end
            end
          end
        end)
      end

      # The `scope` argument, defaulting to this project — the safe direction. An unrecognised
      # value is REFUSED rather than clamped, because clamping "globl" to project would report
      # success for an edit the caller meant to make everywhere.
      private def color_rule_scope(h) : Store::RuleScope | Result
        s = str(h, "scope")
        return Store::RuleScope::Project if s.nil? || s.empty?
        case s.downcase
        when "project" then Store::RuleScope::Project
        when "global"  then Store::RuleScope::Global
        else                err("invalid 'scope' (expected project|global)", "INVALID_ARGUMENT", field: "scope")
        end
      end

      # `Store::MarkerColor.from_label` is deliberately TOLERANT — it has to be, because it also
      # reads a hand-edited settings.json where a raise would take every other section down with
      # it. An argument an agent just typed is the opposite case and gets told it was wrong.
      private def marker_color(h, dft : Store::MarkerColor) : Store::MarkerColor | Result
        s = str(h, "color")
        return dft if s.nil? || s.empty?
        return err("invalid 'color' (expected #{Settings::COLORMARKER_COLORS.join("|")})",
          "INVALID_ARGUMENT", field: "color") unless Settings::COLORMARKER_COLORS.includes?(s.downcase)
        Store::MarkerColor.from_label(s)
      end

      private def marker_style(h, dft : Store::MarkerStyle) : Store::MarkerStyle | Result
        s = str(h, "style")
        return dft if s.nil? || s.empty?
        return err("invalid 'style' (expected full|strip)",
          "INVALID_ARGUMENT", field: "style") unless Settings::COLORMARKER_STYLES.includes?(s.downcase)
        Store::MarkerStyle.from_label(s)
      end

      private def create_color_rule(h) : Result
        filter = str(h, "when")
        return err("missing required 'when'", "INVALID_ARGUMENT", field: "when") if filter.nil?
        # The engine owns what is legal, so the TUI form, the CLI and this surface cannot
        # disagree. All three refusals name a rule that would otherwise fail SILENTLY.
        if reason = Gori::Colormarker.unusable_reason(filter)
          return err(reason, "INVALID_ARGUMENT", field: "when")
        end
        scope = color_rule_scope(h)
        return scope if scope.is_a?(Result)
        color = marker_color(h, Store::MarkerColor::Yellow)
        return color if color.is_a?(Result)
        style = marker_style(h, Store::MarkerStyle::Full)
        return style if style.is_a?(Result)
        name = str(h, "name") || ""
        # Atomic disabled creation: insert already-disabled so there is no window where a
        # just-created rule paints before a follow-up disable call.
        enabled = bool_arg(h, "enabled", true)
        id =
          if scope.global?
            Settings.add_colormarker_rule(filter, color.label, style.label, name, enabled)
          else
            store.insert_color_rule(filter, color, style, name, enabled)
          end
        if id == 0
          return busy(scope.global? ? "failed to persist global colour rule (settings not writable)" : "failed to persist colour rule (store busy or unwritable)")
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "scope", scope.label
            j.field "color", color.label
            j.field "style", style.label
            j.field "enabled", enabled
            # The advisory channel. `InterceptFilter` cannot fail to compile, so a condition
            # that will behave surprisingly cannot be caught by a parse error — these say so
            # without refusing something legitimate.
            color_rule_notes(j, filter)
          end
        end)
      end

      private def color_rule_notes(j : JSON::Builder, filter : String) : Nil
        notes = Gori::Colormarker.advise(filter)
        return if notes.empty?
        j.field "notes" { j.array { notes.each { |n| j.string n } } }
      end

      private def update_color_rule(h) : Result
        id = int(h, "id")
        return err(id_error(h, "id"), "INVALID_ARGUMENT", field: "id") unless id
        scope = color_rule_scope(h)
        return scope if scope.is_a?(Result)
        existing = Gori::Colormarker.merged(store).find { |r| r.id == id && r.scope == scope }
        return not_found("no #{scope.label} colour rule with id #{id}") unless existing
        # Every field is optional: omitted means unchanged.
        filter = str(h, "when") || existing.match_filter
        if reason = Gori::Colormarker.unusable_reason(filter)
          return err(reason, "INVALID_ARGUMENT", field: "when")
        end
        color = marker_color(h, existing.color)
        return color if color.is_a?(Result)
        style = marker_style(h, existing.style)
        return style if style.is_a?(Result)
        name = str(h, "name") || existing.name
        ok =
          if scope.global?
            Settings.update_colormarker_rule(id, filter, color.label, style.label, name)
          else
            store.update_color_rule(id, filter, color, style, name)
          end
        return busy("colour rule NOT updated (store busy or unwritable); the row colour is unchanged") unless ok
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "scope", scope.label
            j.field "when", filter
            j.field "color", color.label
            j.field "style", style.label
            color_rule_notes(j, filter)
          end
        end)
      end

      # For a global rule this writes THIS PROJECT's override by default — the same meaning `x`
      # has in the Colormarker tab. `everywhere: true` changes the library's own default
      # instead, which reaches every project that has not overridden it.
      private def set_color_rule_enabled(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        scope = color_rule_scope(h)
        return scope if scope.is_a?(Result)
        enabled = optional_bool_arg(h, "enabled")
        return Result.new("missing required 'enabled' (true|false)", is_error: true) if enabled.nil?
        everywhere = bool_arg(h, "everywhere", false)
        return err("'everywhere' needs scope=global — a project rule has no default", "INVALID_ARGUMENT", field: "everywhere") if everywhere && !scope.global?
        return not_found("no #{scope.label} colour rule with id #{id}") unless color_rule_exists?(id, scope)
        ok =
          if !scope.global?
            store.set_color_rule_enabled(id, enabled)
          elsif everywhere
            Settings.set_colormarker_rule_enabled(id, enabled)
          else
            set_global_color_rule_enabled_here(id, enabled)
          end
        return busy("enable/disable NOT applied (store busy or unwritable); the row colour is unchanged") unless ok
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "scope", scope.label
            j.field "enabled", enabled
            j.field "everywhere", everywhere if scope.global?
          end
        end)
      end

      # Make a global colour rule effectively `enabled` in THIS project. Agreeing with the
      # library's default CLEARS the override instead of pinning it, so the project keeps
      # following a later change to that default — the disposition `Colormarker#toggle`
      # documents, and the third place it is spelled out (engine, CLI, here).
      private def set_global_color_rule_enabled_here(id : Int64, enabled : Bool) : Bool
        rule = Settings.colormarker_rules.find { |r| r.id == id }
        return false unless rule
        rule.enabled == enabled ? store.clear_colormarker_override(id) : store.set_colormarker_override(id, enabled)
      end

      private def delete_color_rule(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        scope = color_rule_scope(h)
        return scope if scope.is_a?(Result)
        return not_found("no #{scope.label} colour rule with id #{id}") unless color_rule_exists?(id, scope)
        ok =
          if scope.global?
            deleted = Settings.delete_colormarker_rule(id)
            # ONLY once the rule is actually gone. Existence was established above, so a false
            # here means "settings not saved" — and clearing the override then would drop this
            # project back to a default the operator explicitly overrode.
            store.clear_colormarker_override(id) if deleted
            deleted
          else
            store.delete_color_rule(id)
          end
        return busy("colour rule NOT deleted (store busy or unwritable); the row colour is unchanged") unless ok
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "scope", scope.label; j.field "deleted", true } })
      end

      # Reorder within a scope. The scope boundary is not a position: every global rule resolves
      # before every project one, so moving past the end of a block is a scope change.
      private def move_color_rule(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        scope = color_rule_scope(h)
        return scope if scope.is_a?(Result)
        dir_s = str(h, "direction")
        dir =
          case dir_s.try(&.downcase)
          when "up"   then -1
          when "down" then 1
          else             return err("invalid 'direction' (expected up|down)", "INVALID_ARGUMENT", field: "direction")
          end
        return not_found("no #{scope.label} colour rule with id #{id}") unless color_rule_exists?(id, scope)
        scoped = Gori::Colormarker.merged(store).select { |r| r.scope == scope }
        # `color_rule_exists?` above already established the id is in this scope, so the index
        # is present — but derive the bound from `index?` anyway rather than asserting it, so a
        # future caller that skips the guard gets a refusal instead of a nil dereference.
        i = scoped.index { |r| r.id == id }
        j2 = i ? i + dir : -1
        if i.nil? || j2 < 0 || j2 >= scoped.size
          return err("colour rule #{id} is already at the #{dir < 0 ? "top" : "bottom"} of the #{scope.label} block",
            "INVALID_ARGUMENT", field: "direction")
        end
        if scope.global?
          return busy("colour rule NOT moved (settings not writable)") unless Settings.move_colormarker_rule(id, dir)
        else
          store.move_color_rule(id, dir)
        end
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "scope", scope.label; j.field "moved", dir_s } })
      end

      # How many recent flows a candidate condition would MATCH, and how many it would actually
      # PAINT once the rules that already resolve ahead of it are counted. The second number is
      # the one that answers "will I see this": an earlier enabled rule may already claim the row.
      private def preview_color_rule(h) : Result
        filter = str(h, "when")
        return err("missing required 'when'", "INVALID_ARGUMENT", field: "when") if filter.nil?
        if reason = Gori::Colormarker.unusable_reason(filter)
          return err(reason, "INVALID_ARGUMENT", field: "when")
        end
        limit = (int(h, "limit") || Gori::Colormarker::PREVIEW_SCAN.to_i64).to_i.clamp(1, 5000)
        existing = Gori::Colormarker.merged(store)
        pv = Gori::Colormarker.preview(store, filter, existing, limit)
        Result.new(JSON.build do |j|
          j.object do
            j.field "would_match", pv.matched
            j.field "would_paint", pv.painted
            j.field "scanned", pv.scanned
            j.field "total_flows", pv.total
            j.field "scan_capped", pv.total > pv.scanned
            color_rule_notes(j, filter)
          end
        end)
      end

      # Whether a colour rule id exists IN THAT SCOPE. A full read (neither store has a
      # single-row fetch), but the rule set is tiny and these are low-frequency actions.
      private def color_rule_exists?(id : Int64, scope : Store::RuleScope) : Bool
        if scope.global?
          Settings.colormarker_rules.any? { |r| r.id == id }
        else
          store.color_rules.any? { |r| r.id == id }
        end
      end
    end
  end
end
