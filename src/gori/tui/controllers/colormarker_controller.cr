require "../tab_controller"
require "../colormarker_view"
require "../../store"
require "../../colormarker"

module Gori::Tui
  # The Colormarker tab: manage this project's History row-colour rules (the shared Colormarker
  # engine History's row loop reads live). Add/edit opens ColormarkerRuleOverlay, modal, wired
  # in the runner like the Rewriter rule editor.
  #
  # Deliberately smaller than RewriterController: one list, no sub-tabs, no text buffer, no read
  # pane. That is why this controller does NOT join the runner's `flush_active_tab_edits` /
  # subtab / read-pane ladders — there is no buffer to flush and no caret to select with, and a
  # no-op `commit` here would be dead code asserting a buffer exists.
  class ColormarkerController < TabController
    def initialize(host : Host)
      super(host)
      @view = ColormarkerView.new
      @sel = 0
      @scroll = 0
      @last_body = Rect.new(0, 0, 0, 0) # last content rect — click/wheel geometry
    end

    def tab : Symbol
      :colormarker
    end

    def command_scope : Verb::Scope
      Verb::Scope::Colormarker
    end

    # `command_section` is deliberately NOT overridden. Rewriter needs one because it has a
    # second focus area whose read verbs reuse this list's letters; here there is one view, so
    # the default `:common` is the whole story and nothing can collide inside it.

    private def engine : Colormarker
      @host.session.colormarker
    end

    private def rule_list : Array(Store::ColorRule)
      engine.rules
    end

    def selected_rule : Store::ColorRule?
      rule_list[@sel]?
    end

    def rule_selected? : Bool
      !selected_rule.nil?
    end

    def global_rule_selected? : Bool
      selected_rule.try(&.global?) == true
    end

    # Pull external (MCP / CLI / other-instance) rule edits when the tab becomes active.
    def on_enter : Nil
      engine.reload
      @sel = @sel.clamp(0, {rule_list.size - 1, 0}.max)
    end

    def on_external_change : Nil
      engine.reload
    end

    # --- render ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      # multi_pane: false — one list, no second pane to hand focus to.
      BodyChrome.framed(screen, rect, BodyChrome.shell_focused(focus, multi_pane: false)) do |inner|
        @last_body = inner
        list = rule_list
        @sel = @sel.clamp(0, {list.size - 1, 0}.max)
        ensure_visible(inner, list.size)
        @view.render(screen, inner, list, @sel, @scroll, engine.enabled_count, body_focused)
      end
    end

    private def ensure_visible(inner : Rect, count : Int32) : Nil
      lh = @view.row_capacity(inner, count)
      return if lh <= 0
      if @sel < @scroll
        @scroll = @sel
      elsif @sel >= @scroll + lh
        @scroll = @sel - lh + 1
      end
      @scroll = @scroll.clamp(0, {count - lh, 0}.max)
    end

    def body_hint(focus : Symbol) : String
      "↑/↓ select · a add · ↵/e edit · x on/off · s scope · ⇧J/⇧K reorder · d delete"
    end

    # --- keys ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.space? && !ev.ctrl? && !ev.alt? then @host.open_space_menu
      when key.up?, c == 'k'                   then move_up
      when key.down?, c == 'j'                 then move_sel(1)
      when key.escape?                         then @host.request_focus(:menu)
      else                                          return handle_action_key(ev, c)
      end
      true
    end

    # ↑/k at the top of the list releases focus back to the tab bar, like the Rewriter's.
    private def move_up : Nil
      if @sel <= 0
        @host.request_focus(:menu)
      else
        move_sel(-1)
      end
    end

    private def handle_action_key(ev : Termisu::Event::Key, c : Char?) : Bool
      key = ev.key
      case
      when key.enter?, c == 'e' then colormarker_edit
      when c == 'a'             then colormarker_add
      when c == 'd'             then colormarker_delete
      when c == 'x'             then colormarker_toggle
      when c == 'X'             then colormarker_toggle_default
      when c == 's'             then colormarker_scope_toggle
      when c == 'J'             then colormarker_move(1)
      when c == 'K'             then colormarker_move(-1)
      else                           return false
      end
      true
    end

    private def move_sel(d : Int32) : Nil
      n = rule_list.size
      return if n == 0
      @sel = (@sel + d).clamp(0, n - 1)
    end

    # --- mouse ---
    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      inner = BodyChrome.frame_inner(rect)
      @last_body = inner
      # `row_at` already refuses the note row and anything past the last rule, so a hit is
      # a real index — the clamp below is the belt to its braces, not the bounds check.
      if idx = @view.row_at(inner, my, @scroll, rule_list.size)
        @sel = idx.clamp(0, {rule_list.size - 1, 0}.max)
      end
      true
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      handle_click(rect, mx, my)
      colormarker_edit
      true
    end

    def handle_wheel(step : Int32) : Bool
      return false if @last_body.empty?
      count = rule_list.size
      lh = @view.row_capacity(@last_body, count)
      return false if lh <= 0
      @scroll = (@scroll + step).clamp(0, {count - lh, 0}.max)
      true
    end

    # --- actions (also the ExecContext verbs) ---

    def colormarker_add : Nil
      @host.open_colormarker_rule_editor(nil)
    end

    def colormarker_edit : Nil
      if rule = selected_rule
        @host.open_colormarker_rule_editor(rule)
      else
        @host.status("no colour rule selected")
      end
    end

    def colormarker_delete : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      label = rule.name.empty? ? rule.match_filter : rule.name
      # A global rule is deleted out of EVERY project, and the prompt has to say so — the row
      # differs from a project rule's by one badge, and the confirm is the last place to notice.
      note = rule.global? ? " It is a GLOBAL rule — this removes it from every project." : ""
      @host.confirm("DELETE COLOUR RULE", "Delete “#{label}”?#{note} This can't be undone.",
        confirm_label: "delete", danger: true) do
        # The store's answer, not an assumption. The failure text says what is actually still
        # true — the row keeps its colour — rather than borrowing the Rewriter's "still
        # rewriting live traffic", which would be alarmist AND false for a display rule.
        ok = engine.remove(rule.id, rule.scope)
        @sel = @sel.clamp(0, {rule_list.size - 1, 0}.max)
        @host.status(ok ? "colour rule deleted" : "rule NOT deleted (project busy) — the row colour is unchanged")
      end
    end

    # `x` toggles the rule HERE. For a project rule that is the row itself; for a global one it
    # is this project's override of the library's default, which is why the toast says where the
    # change lands — the same keypress means "not in this engagement", not "not anywhere"
    # (that is ⇧X).
    def colormarker_toggle : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      unless engine.toggle(rule.id, rule.scope)
        return @host.status("enable/disable NOT applied (project busy) — the row colour is unchanged")
      end
      state = rule.enabled? ? "disabled" : "enabled"
      @host.status(rule.global? ? "global colour rule #{state} in this project" : "colour rule #{state}")
    end

    # ⇧X: the global DEFAULT — what every project that has not overridden this rule follows.
    def colormarker_toggle_default : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      return @host.status("only a global rule has a default — this one is project-scoped") unless rule.global?
      unless engine.toggle_default(rule.id, rule.scope)
        return @host.status("default NOT changed (settings not writable) — the rule is unchanged")
      end
      after = rule_list.find { |r| r.global? && r.id == rule.id }
      note = after.try(&.overridden?) ? " (this project still overrides it)" : ""
      @host.status("global colour rule default flipped for every project#{note}")
    end

    # Reordering here changes WHICH rule paints a row (first enabled match wins), so the toast
    # says that rather than leaving an operator to infer it from a list that merely shuffled.
    def colormarker_move(dir : Int32) : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      # Only follow the rule when it actually moved: ⇧J on the last GLOBAL rule cannot push it
      # into the project block (that is a scope change, `s`).
      if engine.move(rule.id, dir, rule.scope)
        move_sel(dir)
        @host.status("precedence changed — the first enabled match paints the row")
      end
    end

    def colormarker_duplicate : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      name = rule.name.empty? ? "" : "#{rule.name} copy"
      engine.add(rule.match_filter, rule.color, rule.style, name, scope: rule.scope)
      @host.status(rule.global? ? "global colour rule duplicated" : "colour rule duplicated")
    end

    # `s`: move the selected rule between the global library and this project. The rule keeps
    # its fields and the state it has HERE; what changes is who else sees it.
    def colormarker_scope_toggle : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      to = rule.global? ? Store::RuleScope::Project : Store::RuleScope::Global
      unless engine.set_scope(rule, to)
        return @host.status("scope NOT changed (project busy or settings not writable) — the rule is unchanged")
      end
      # The rule moved between the two blocks, so its row moved too. It lands at the END of the
      # destination block (both stores append), which is an exact answer where matching on the
      # fields would pick the wrong twin among duplicates.
      @sel = last_index_of_scope(to)
      @host.status(to.global? ? "colour rule is now GLOBAL — it applies in every project" : "colour rule is now project-scoped")
    end

    def colormarker_reload : Nil
      engine.reload
      @host.status("colour rules reloaded")
    end

    # Commit the editor overlay: add a new rule or update the edited one, then re-select it.
    # The form's `scope:` row is part of the edit — changing it on an existing rule MOVES the
    # rule between the two stores (fields first, then the re-home, so a refused move leaves the
    # edit applied rather than silently dropping both halves).
    def apply_color_rule(ov : ColormarkerRuleOverlay) : Bool
      return false unless ov.valid?
      if id = ov.edit_id
        from = ov.edit_scope || Store::RuleScope::Project
        engine.update(id, ov.condition, ov.color, ov.style, ov.name, scope: from)
        if from != ov.scope
          moved = rule_list.find { |r| r.scope == from && r.id == id }
          if moved && !engine.set_scope(moved, ov.scope)
            @host.status("rule saved, but the scope change did not commit — it is still #{from.label}")
          end
        end
      else
        engine.add(ov.condition, ov.color, ov.style, ov.name, scope: ov.scope)
        # A global rule lands at the end of the GLOBAL block, which is not the end of the list.
        @sel = last_index_of_scope(ov.scope)
      end
      true
    end

    private def last_index_of_scope(scope : Store::RuleScope) : Int32
      idx = rule_list.rindex { |r| r.scope == scope }
      idx || {rule_list.size - 1, 0}.max
    end
  end
end
