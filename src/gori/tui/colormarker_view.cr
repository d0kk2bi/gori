require "./frame"
require "./theme"

module Gori::Tui
  # The Colormarker tab body: one list of row-colour rules, and nothing else.
  #
  # Stateless, like `RewriterView` — it takes the current state and draws it. Unlike that view
  # there is no sub-tab strip and no preview pair: a colour rule has no transformed sample to
  # show (the "preview" is History itself), so the card fills the body and the match count rides
  # the rule editor's own panel instead.
  class ColormarkerView
    LIST_MIN_H = 3

    # Visible row count inside the list card, for scroll clamping.
    def row_capacity(rect : Rect) : Int32
      inner = rect.inset(1, 1)
      {inner.h, 0}.max
    end

    # Which row index sits under `my`, or nil. Y-only, like every other list here.
    def row_at(rect : Rect, my : Int32, scroll : Int32) : Int32?
      inner = rect.inset(1, 1)
      return nil if inner.empty? || my < inner.y || my >= inner.bottom
      scroll + (my - inner.y)
    end

    def render(screen : Screen, rect : Rect, rules : Array(Store::ColorRule),
               sel : Int32, scroll : Int32, enabled_count : Int32, focused : Bool) : Nil
      return if rect.w < 6 || rect.h < LIST_MIN_H
      Frame.card(screen, rect, "COLORMARKER", bg: Theme.bg, border: Frame.pane_border(focused))
      meta = "#{enabled_count}/#{rules.size} enabled"
      # How many come from the global library, so the split stays legible when the list is
      # scrolled past the `G` rows. Only when there ARE any — a project with none should not
      # pay border width to be told "0 global".
      globals = rules.count(&.global?)
      meta = "#{globals} global · #{meta}" if globals > 0
      if rect.w > meta.size + 18
        screen.text({rect.right - meta.size - 2, rect.x + 16}.max, rect.y, meta, Theme.muted, Theme.bg)
      end
      inner = rect.inset(1, 1)
      return if inner.empty?

      list_top = inner.y
      list_h = inner.h
      # A one-line reminder of the resolution rule, stolen from the bottom when there is more
      # than one rule. It is the single thing about this list an operator most often gets wrong
      # (rewrite rules next door COMPOSE), and it only matters once two rules can contend.
      if rules.size > 1 && list_h > 2
        screen.text(inner.x, inner.bottom - 1, "first enabled match wins — u/n reorder",
          Theme.muted, Theme.bg, width: inner.w)
        list_h -= 1
      end

      if rules.empty?
        screen.text(inner.x, list_top, "no colour rules — press a to add",
          Theme.muted, Theme.bg, width: inner.w)
        return
      end

      (0...list_h).each do |i|
        idx = scroll + i
        break if idx >= rules.size
        render_row(screen, inner, rules[idx], list_top + i, idx == sel, focused)
      end
    end

    private def render_row(screen : Screen, rect : Rect, rule : Store::ColorRule, py : Int32,
                           selected : Bool, focused : Bool) : Nil
      bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(rect.x, py, rect.w, 1), bg)
      screen.cell(rect.x, py, selected ? '▎' : ' ', Theme.accent, bg)
      x = rect.x + 2
      screen.cell(x, py, rule.enabled? ? '✓' : '·', rule.enabled? ? Theme.accent : Theme.muted, bg)
      x += 2
      x = render_scope_badge(screen, rule, x, py, bg)

      # The swatch, drawn at full saturation whether or not the rule is enabled — it says what
      # colour this rule IS, and dimming it would make a disabled red and a disabled orange
      # indistinguishable in exactly the list where you go to tell them apart. The ✓/· two
      # columns left already carries the on/off answer.
      hue = Theme.mark_color(rule.color.to_sym)
      # A `full` rule shows a two-cell BAND, a `strip` rule the one-cell block it actually
      # paints — so the row previews its own effect rather than naming it twice.
      if rule.style.full?
        screen.cell(x, py, ' ', hue, Theme.row_tint(hue, bg))
        screen.cell(x + 1, py, ' ', hue, Theme.row_tint(hue, bg))
      else
        screen.cell(x, py, '█', hue, bg)
        screen.cell(x + 1, py, ' ', hue, bg)
      end
      x += 3

      fg = rule.enabled? ? (selected ? Theme.text_bright : Theme.text) : Theme.muted
      style = rule.style.label.ljust(5)
      screen.text(x, py, style, Theme.muted, bg)
      x += style.size + 1
      unless rule.name.empty?
        nm = "[#{rule.name}]"
        screen.text(x, py, nm, Theme.accent, bg, width: {rect.right - x, 0}.max)
        x += nm.size + 1
      end
      screen.text(x, py, rule.match_filter, fg, bg, width: {rect.right - x, 1}.max) if x < rect.right
    end

    # WHERE the rule lives: `G` = the global library (every project), `P` = this project's own
    # table. `G*` means this project overrides the library's default for it — the ✓/· left of
    # the badge is then THIS project's answer, not the rule's.
    #
    # Always three columns wide, so every field right of it stays aligned down the list.
    private def render_scope_badge(screen : Screen, rule : Store::ColorRule, x : Int32,
                                   py : Int32, bg : Color) : Int32
      badge = rule.overridden? ? "#{rule.scope.badge}*" : rule.scope.badge
      screen.text(x, py, badge, rule.global? ? Theme.env_known : Theme.muted, bg)
      x + 3
    end
  end
end
