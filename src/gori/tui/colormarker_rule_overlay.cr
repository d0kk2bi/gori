require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../store"
require "../colormarker"
require "../intercept_filter"
require "../filter_ast"

module Gori::Tui
  # Popup form to add or edit ONE Colormarker (History row-colour) rule.
  #
  #   ↑/↓ or ↹   move between fields
  #   ←/→         cycle the selected option row (scope / colour / style)
  #   type        edit the focused text row (name / when)
  #   ↹           on the `when:` row, complete the QL token under the caret
  #   ↵           advance a text row (↵ on Save commits) · esc cancels
  #
  # On the polymorphic Overlay seam (see overlay.cr). Both domain couplings are injected at
  # the open-site (Runner#open_colormarker_rule_editor) so the form stays store-free:
  # `on_commit` persists through the shared Colormarker engine, `on_preview` scans recent
  # flows for the live match count, and `on_hosts` supplies the `host:` completion pool.
  class ColormarkerRuleOverlay < Overlay
    ROW_NAME = 0
    # The three cyclers sit CONTIGUOUSLY between the two text rows, so `cycler_row?` stays a
    # range check rather than a set membership test — ←/→ versus typing then dispatches on one
    # comparison, the way RewriterRuleOverlay's does.
    ROW_SCOPE = 1
    ROW_COLOR = 2
    ROW_STYLE = 3
    ROW_WHEN  = 4
    ROW_SAVE  = 5
    ROW_COUNT = 6

    SCOPES       = %w[project global]
    SCOPE_LABELS = ["this project", "global (every project)"]
    COLORS       = %w[red orange yellow green blue purple]
    STYLES       = %w[full strip]
    STYLE_LABELS = ["full row", "strip"]

    getter edit_id : Int64?
    # The scope the edited rule was OPENED at, so the commit can tell an edit from a re-home:
    # `scope` is the cycler's current value and these two differing is the whole signal that
    # the rule has to move between the project table and the global library.
    getter edit_scope : Store::RuleScope?

    # Renders the "matches N of M recent flows" line under the form. Injected at the open-site
    # because it READS TRAFFIC — the form itself stays store-free.
    property on_preview : Proc(Store::ColorRule, String)?
    # Host candidates for `host:` completion, prefix-filtered by the caller. Injected for the
    # same reason: `Store#distinct_hosts` is a query.
    property on_hosts : Proc(String, Array(String))?

    @scope_i : Int32
    @color_i : Int32
    @style_i : Int32
    @sel : Int32
    @preview : String = ""
    # Last previewed field set; gates the rescan to real changes.
    @preview_sig : String = ""

    def initialize(*, name : String = "", match_filter : String = "", color : String = "yellow",
                   style : String = "full", scope : String = "project",
                   @edit_id : Int64? = nil, @edit_scope : Store::RuleScope? = nil)
      @fields = {
        name: TextField.new(name),
        when: TextField.new(match_filter),
      }
      @scope_i = idx(SCOPES, scope)
      @color_i = idx(COLORS, color)
      @style_i = idx(STYLES, style)
      @sel = 0
    end

    def self.adding : ColormarkerRuleOverlay
      new
    end

    def self.editing(rule : Store::ColorRule) : ColormarkerRuleOverlay
      new(name: rule.name, match_filter: rule.match_filter, color: rule.color.label,
        style: rule.style.label, scope: rule.scope.label, edit_id: rule.id,
        edit_scope: rule.scope)
    end

    private def idx(list : Array(String), v : String) : Int32
      list.index(v) || 0
    end

    def editing? : Bool
      !@edit_id.nil?
    end

    def name : String
      @fields[:name].value
    end

    def condition : String
      @fields[:when].value
    end

    def color : Store::MarkerColor
      Store::MarkerColor.from_label(COLORS[@color_i])
    end

    def style : Store::MarkerStyle
      Store::MarkerStyle.from_label(STYLES[@style_i])
    end

    def scope : Store::RuleScope
      Store::RuleScope.from_label(SCOPES[@scope_i])
    end

    # `InterceptFilter.new` never raises, so validity cannot lean on a parse failure. All three
    # refusals live on the engine, where the CLI and MCP surfaces read the same answer — a form
    # with its own opinion is how the three surfaces end up disagreeing about what is legal.
    def valid? : Bool
      Colormarker.unusable_reason(condition).nil?
    end

    def invalid_reason : String
      Colormarker.unusable_reason(condition) || ""
    end

    # A live rule for the preview scan. `enabled` is true regardless of anything: the question
    # the preview answers is "what WOULD this paint".
    def candidate_rule : Store::ColorRule
      Store::ColorRule.new(@edit_id || 0_i64, true, condition, color, style, name, scope: scope)
    end

    # No `skip_row?` — every row applies to every colour rule, so this is a plain clamp rather
    # than the walk-past-ignored-rows loop RewriterRuleOverlay needs for its op-dependent form.
    def move(d : Int32) : Nil
      @sel = (@sel + (d < 0 ? -1 : 1)).clamp(0, ROW_COUNT - 1)
    end

    def set_selected(idx : Int32) : Nil
      @sel = idx.clamp(0, ROW_COUNT - 1)
    end

    private def cycler_row?(row : Int32) : Bool
      ROW_SCOPE <= row <= ROW_STYLE
    end

    private def text_field_for(row : Int32) : TextField?
      case row
      when ROW_NAME then @fields[:name]
      when ROW_WHEN then @fields[:when]
      end
    end

    def adjust(d : Int32) : Nil
      case @sel
      when ROW_SCOPE then @scope_i = (@scope_i + d) % SCOPES.size
      when ROW_COLOR then @color_i = (@color_i + d) % COLORS.size
      when ROW_STYLE then @style_i = (@style_i + d) % STYLES.size
      end
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::ColormarkerRule
    end

    def title : String
      "COLORMARKER RULE"
    end

    def text_fields : Array(TextField)
      @fields.values.to_a
    end

    def hint : String
      "↑/↓ field · ←/→ options · ↹ complete · ↵ save · esc cancel"
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      out = edit_key(ev)
      refresh_preview if out == :stay
      out
    end

    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit if @sel == ROW_SAVE
      end
      click_text_field(mx, my)
      :stay
    end

    private def edit_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?

      # ↹ on the condition row completes the QL token under the caret — but ONLY when there IS
      # one, and this arm has to come BEFORE the field-nav arm below or the completion is
      # unreachable. `InterceptFilter.suggestions` returns empty on blank space and on a token
      # nothing matches (the operator is then deliberately free-texting a word), so in those
      # cases ↹ falls through to field navigation, which is what it means on every other row.
      # ⇧↹ is never claimed here, so there is always a keyboard way back up.
      return :stay if @sel == ROW_WHEN && key.tab? && !ev.shift? && complete_condition

      if key.up? || key.back_tab?
        move(-1)
        return :stay
      elsif key.down? || key.tab?
        move(1)
        return :stay
      end

      if cycler_row?(@sel)
        case
        when key.left?              then adjust(-1)
        when key.right?             then adjust(1)
        when key.enter?, key.space? then move(1)
        end
        :stay
      elsif @sel == ROW_SAVE
        (key.enter? || key.space?) ? :commit : :stay
      else # text row
        field = text_field_for(@sel)
        if key.enter?
          return :commit if @sel == ROW_WHEN
          move(1)
        elsif field
          field.handle_edit_key(ev)
        end
        :stay
      end
    end

    # Splice the first suggestion for the token under the caret. False when there is nothing to
    # complete, which is what lets ↹ mean "next field" in that case.
    private def complete_condition : Bool
      field = @fields[:when]
      sugg = suggestions
      return false if sugg.empty?
      cur = FilterAst.token_at(field.value, field.caret)
      first = sugg.first
      field.set("#{field.value[0, cur.start]}#{first}#{field.value[cur.stop..]}",
        caret: cur.start + first.size)
      true
    end

    # The completion candidates for the caret's token — also rendered as the bottom band while
    # the condition row has focus, so the completion is visible BEFORE it is used.
    def suggestions : Array(String)
      field = @fields[:when]
      hosts = @on_hosts.try(&.call(host_prefix(field))) || [] of String
      InterceptFilter.suggestions(field.value, field.caret, hosts)
    end

    private def host_prefix(field : TextField) : String
      cur = FilterAst.token_at(field.value, field.caret)
      core = cur.core
      return "" unless (colon = core.index(':')) && core[0...colon].downcase == "host"
      FilterAst.unquote_prefix(core[(colon + 1)..])
    end

    def set_preedit(text : String) : Nil
      text_field_for(@sel).try(&.set_preedit(text))
    end

    # Rescan only when a MATCH-relevant field changed, so typing a name stays responsive. The
    # colour and style are not in the signature: neither changes which flows match.
    private def refresh_preview : Nil
      sig = condition
      return if sig == @preview_sig
      @preview_sig = sig
      @preview = valid? ? (@on_preview.try(&.call(candidate_rule)) || "") : ""
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 72}.min
      h = {area.h - 2, ROW_COUNT + 5}.min # title + rows + preview/suggestions + hint + padding
      return nil if w < 40 || h < 10
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "colormarker-rule form needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, editing? ? "EDIT COLOUR RULE" : "ADD COLOUR RULE", border: Theme.border_focus)
      first = box.y + 2
      ROW_COUNT.times do |i|
        py = first + i
        break if py >= box.bottom - 2
        draw_row(screen, box, i, py)
      end

      # The bottom band is dual-purpose: on the condition row it advertises what ↹ would
      # complete, everywhere else it reports what the rule would paint.
      pv_y = box.bottom - 2
      if pv_y > first
        band = @sel == ROW_WHEN ? completion_band : (@preview.empty? ? "" : "▶ #{@preview}")
        unless band.empty?
          screen.fill(Rect.new(box.x + 1, pv_y, box.w - 2, 1), Theme.panel)
          screen.text(box.x + 2, pv_y, band, Theme.muted, Theme.panel, width: box.w - 4)
        end
      end
      hint_y = box.bottom - 1
      screen.text(box.x + 2, hint_y, hint, Theme.muted, Theme.panel, width: box.w - 4) if hint_y > first
    end

    private def completion_band : String
      sugg = suggestions
      return "↹ #{sugg.first(6).join("  ")}" unless sugg.empty?
      # No candidates: say what this backend actually knows, since the QL fields History's
      # search bar accepts are a SUPERSET and reaching for one of them is the likely mistake.
      "fields: #{Colormarker::USEFUL_FIELDS.join(": ")}:"
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @sel
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      fg = sel ? Theme.text_bright : Theme.text
      case i
      when ROW_NAME  then draw_field(screen, box, py, bg, fg, sel, "name:", @fields[:name])
      when ROW_SCOPE then draw_cycle(screen, x, py, bg, fg, "scope:", SCOPE_LABELS, @scope_i, sel)
      when ROW_COLOR then draw_color_cycle(screen, x, py, bg, sel)
      when ROW_STYLE then draw_style_cycle(screen, x, py, bg, fg, sel)
      when ROW_WHEN  then draw_field(screen, box, py, bg, fg, sel, "when:", @fields[:when])
      else
        ok = valid?
        label = ok ? "[ Save rule ]" : "[ #{invalid_reason} ]"
        screen.text(x, py, label, ok ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      end
    end

    # Each option is drawn as its own swatch plus a label. The swatch keeps its true hue whether
    # or not the option is lit — the row is then a legible palette strip, and the selection is
    # carried by the LABEL's weight. Dimming unlit swatches would make the one row whose job is
    # "show me the colours" the row that shows them wrong.
    private def draw_color_cycle(screen : Screen, x : Int32, py : Int32, bg : Color, row_sel : Bool) : Nil
      screen.text(x, py, "colour:", Theme.muted, bg)
      tx = x + 8
      COLORS.each_with_index do |opt, oi|
        lit = oi == @color_i
        screen.cell(tx, py, '█', Theme.mark_color(Store::MarkerColor.from_label(opt).to_sym), bg)
        col = lit ? (row_sel ? Theme.text_bright : Theme.accent) : Theme.muted
        tx = screen.text(tx + 1, py, "#{opt} ", col, bg, lit ? Attribute::Bold : Attribute::None)
      end
      screen.text(tx, py, "‹/›", Theme.muted, bg) if row_sel
    end

    # The style row carries a live SAMPLE of what the choice does, drawn against `Theme.bg` —
    # NOT against the row's own `bg`. The focused row is filled with `accent_bg`, and previewing
    # a canvas tint on top of the selection band would be a lie about how History will look.
    private def draw_style_cycle(screen : Screen, x : Int32, py : Int32, bg : Color, fg : Color,
                                 row_sel : Bool) : Nil
      draw_cycle(screen, x, py, bg, fg, "style:", STYLE_LABELS, @style_i, row_sel)
      sx = x + 8 + STYLE_LABELS.sum { |s| Screen.draw_width(s) + 2 } + (row_sel ? 4 : 0) + 2
      hue = Theme.mark_color(color.to_sym)
      if style.full?
        screen.text(sx, py, " sample row ", Theme.text_bright, Theme.row_tint(hue, Theme.bg))
      else
        screen.cell(sx, py, '█', hue, Theme.bg)
        screen.text(sx + 1, py, " sample row ", Theme.text, Theme.bg)
      end
    end

    private def draw_cycle(screen : Screen, x : Int32, py : Int32, bg : Color, fg : Color,
                           label : String, opts : Array(String), sel_i : Int32, row_sel : Bool) : Nil
      screen.text(x, py, label, Theme.muted, bg)
      tx = x + label.size + 1
      opts.each_with_index do |opt, oi|
        lit = oi == sel_i
        col = lit ? (row_sel ? Theme.text_bright : Theme.accent) : Theme.muted
        tx = screen.text(tx, py, " #{opt} ", col, bg, lit ? Attribute::Bold : Attribute::None)
      end
      screen.text(tx, py, " ‹/›", Theme.muted, bg) if row_sel
    end

    private def draw_field(screen : Screen, box : Rect, py : Int32, bg : Color, fg : Color,
                           sel : Bool, label : String, field : TextField) : Nil
      x = box.x + 3
      screen.text(x, py, label, Theme.muted, bg)
      vx = x + label.size + 1
      vw = {box.right - 2 - vx, 3}.max
      val = field.value
      pre = field.preedit
      shown = pre.empty? ? val : "#{val[0, field.caret]}#{pre}#{val[field.caret..]}"
      screen.text(vx, py, shown, fg, bg, width: vw)
      if sel && pre.empty?
        cx = field.caret.clamp(0, val.size)
        px = vx + Screen.draw_width(val[0, cx])
        if px < box.right - 2
          ch = cx < val.size ? val[cx] : ' '
          screen.cell(px, py, ch, Theme.bg, Theme.accent_bg)
          screen.cursor(px, py)
        end
      end
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 2)
      (0 <= i < ROW_COUNT) ? i : nil
    end
  end
end
