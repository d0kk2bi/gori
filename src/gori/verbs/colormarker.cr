require "../verb"

module Gori
  module Verbs
    # The Colormarker tab's space-menu / palette actions. The body is a navigable list (not a
    # text editor), so these also bind as direct body keys in the controller; the mnemonics
    # here drive the space menu + palette.
    #
    # All of them are `:common` (the default section), NOT the `:rules` the Rewriter's twins
    # use — and that difference is load-bearing rather than sloppy. Rewriter needs a named
    # section because it has a SECOND focus area (the preview panes) whose read verbs spend `x`
    # on "select line", which `Registry#validate_menu_keys!` refuses to see twice inside one
    # displayable view. Colormarker has one list, no text pane and no sub-tabs, so there is
    # nothing to partition: a displayable view here is `common ∪ {}`, the ten letters below are
    # distinct, and cross-scope reuse is explicitly permitted. This is the same key set Rewriter
    # already ships and passes the boot-time check with.
    def self.register_colormarker(r : Verb::Registry) : Nil
      in_cm = ->(ctx : Verb::ExecContext) { ctx.current_tab == :colormarker }
      has_rule = ->(ctx : Verb::ExecContext) { ctx.current_tab == :colormarker && ctx.colormarker_rule_selected? }

      r.register Verb::Definition.new(
        "colormarker.add", "Add rule", "Open the editor to add a History row-colour rule",
        Verb::Scope::Colormarker, [Verb::Chord.new("a")], available: in_cm, mnemonic: 'a') { |ctx| ctx.colormarker_add; nil }
      r.register Verb::Definition.new(
        "colormarker.edit", "Edit rule", "Edit the selected rule in the popup editor",
        Verb::Scope::Colormarker, [Verb::Chord.new("enter"), Verb::Chord.new("e")], available: has_rule, mnemonic: 'e') { |ctx| ctx.colormarker_edit; nil }
      r.register Verb::Definition.new(
        "colormarker.toggle", "Enable/disable", "Toggle the selected rule on or off in THIS project",
        Verb::Scope::Colormarker, [Verb::Chord.new("x")], available: has_rule, mnemonic: 'x') { |ctx| ctx.colormarker_toggle; nil }
      r.register Verb::Definition.new(
        "colormarker.delete", "Delete rule", "Delete the selected rule (confirms first)",
        Verb::Scope::Colormarker, [Verb::Chord.new("d")], available: has_rule, mnemonic: 'd') { |ctx| ctx.colormarker_delete; nil }
      # "Move up/down" reads like cosmetics on the Rewriter, where rules compose and order is a
      # tiebreak. Here the FIRST enabled match paints the row and the rest are never consulted,
      # so a move changes which rule wins — the descriptions say so rather than leaving an
      # operator to discover it.
      r.register Verb::Definition.new(
        "colormarker.move-up", "Move up", "Give the selected rule higher precedence (first match wins)",
        Verb::Scope::Colormarker, [Verb::Chord.new("k", shift: true)], available: has_rule, mnemonic: 'u') { |ctx| ctx.colormarker_move(-1); nil }
      r.register Verb::Definition.new(
        "colormarker.move-down", "Move down", "Give the selected rule lower precedence (first match wins)",
        Verb::Scope::Colormarker, [Verb::Chord.new("j", shift: true)], available: has_rule, mnemonic: 'n') { |ctx| ctx.colormarker_move(1); nil }
      r.register Verb::Definition.new(
        "colormarker.duplicate", "Duplicate rule", "Copy the selected rule into a new one",
        Verb::Scope::Colormarker, available: has_rule, mnemonic: 'c') { |ctx| ctx.colormarker_duplicate; nil }
      r.register Verb::Definition.new(
        "colormarker.reload", "Reload rules", "Re-read rules from the project DB (pick up external edits)",
        Verb::Scope::Colormarker, available: in_cm, mnemonic: 'r') { |ctx| ctx.colormarker_reload; nil }

      # The scope half, the same shape the Rewriter's carries: a rule lives EITHER in this
      # project or in the global library every project reads. The default-flip is offered only
      # for a global rule, because a project rule has no default to flip — `x` IS its state.
      global_rule = ->(ctx : Verb::ExecContext) { ctx.current_tab == :colormarker && ctx.colormarker_global_rule_selected? }
      r.register Verb::Definition.new(
        "colormarker.scope", "Global/project", "Move the selected rule between this project and the global library",
        Verb::Scope::Colormarker, [Verb::Chord.new("s")], available: has_rule, mnemonic: 's') { |ctx| ctx.colormarker_scope_toggle; nil }
      r.register Verb::Definition.new(
        "colormarker.toggle-default", "Enable/disable everywhere",
        "Flip a GLOBAL rule's default — the state every project without an override follows",
        Verb::Scope::Colormarker, [Verb::Chord.new("x", shift: true)],
        available: global_rule, mnemonic: 'X') { |ctx| ctx.colormarker_toggle_default; nil }
    end
  end
end
