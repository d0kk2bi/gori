require "../verb"

module Gori
  module Verbs
    # The Rewriter tab's space-menu / palette actions. The body is a navigable list (not a
    # text editor), so these also bind as direct body keys in the controller; the mnemonics
    # here drive the space menu + palette.
    #
    # ALL of them are `section: :rules`, not :common, and `RewriterController#command_section`
    # answers `:rules` / `:preview` to match. Two reasons, one structural and one a defect:
    # the PREVIEW OUTPUT pane grew its own read verbs whose `x` means "select line" — the same
    # letter this list spends on "Enable/disable", which `Registry#validate_menu_keys!` refuses
    # inside one displayable view — and, before that, the menu offered every rule action while
    # the preview pane held focus, acting on a row the operator was not looking at. That is the
    # leak `Runner#rewriter_rule_selected?` documents, one axis over: it remembered `@sub` and
    # forgot `@focus`.
    def self.register_rewriter(r : Verb::Registry) : Nil
      in_rw = ->(ctx : Verb::ExecContext) { ctx.current_tab == :rewriter }
      has_rule = ->(ctx : Verb::ExecContext) { ctx.current_tab == :rewriter && ctx.rewriter_rule_selected? }

      r.register Verb::Definition.new(
        "rewriter.add", "Add rule", "Open the editor to add a Match & Replace rule",
        Verb::Scope::Rewriter, available: in_rw, mnemonic: 'a', section: :rules) { |ctx| ctx.rewriter_add; nil }
      r.register Verb::Definition.new(
        "rewriter.edit", "Edit rule", "Edit the selected rule in the popup editor",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'e', section: :rules) { |ctx| ctx.rewriter_edit; nil }
      r.register Verb::Definition.new(
        "rewriter.toggle", "Enable/disable", "Toggle the selected rule on or off in THIS project",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'x', section: :rules) { |ctx| ctx.rewriter_toggle; nil }
      r.register Verb::Definition.new(
        "rewriter.delete", "Delete rule", "Delete the selected rule (confirms first)",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'd', section: :rules) { |ctx| ctx.rewriter_delete; nil }
      r.register Verb::Definition.new(
        "rewriter.move-up", "Move up", "Move the selected rule earlier in apply order",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'u', section: :rules) { |ctx| ctx.rewriter_move(-1); nil }
      r.register Verb::Definition.new(
        "rewriter.move-down", "Move down", "Move the selected rule later in apply order",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'n', section: :rules) { |ctx| ctx.rewriter_move(1); nil }
      r.register Verb::Definition.new(
        "rewriter.duplicate", "Duplicate rule", "Copy the selected rule into a new one",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'c', section: :rules) { |ctx| ctx.rewriter_duplicate; nil }
      r.register Verb::Definition.new(
        "rewriter.reload", "Reload rules", "Re-read rules from the project DB (pick up external edits)",
        Verb::Scope::Rewriter, available: in_rw, mnemonic: 'r', section: :rules) { |ctx| ctx.rewriter_reload; nil }

      # The scope half. A Match & Replace rule lives EITHER in this project or in the global
      # library that every project reads (`Store::RuleScope`) — this replaces the old s/o
      # preset library, whose recipes did nothing until you loaded a copy into each project.
      # `s` keeps the mnemonic the save half had, now meaning "which scope".
      #
      # The default-flip is offered only for a global rule, because a project rule has no
      # default to flip: `x` IS its state. Both gate on a selected rule for the reason
      # `rewriter_rule_selected?` documents — the menu must not act on a row the operator
      # cannot see from the `extract` / `bindings` sub-tabs.
      global_rule = ->(ctx : Verb::ExecContext) { ctx.current_tab == :rewriter && ctx.rewriter_global_rule_selected? }
      r.register Verb::Definition.new(
        "rewriter.scope", "Global/project", "Move the selected rule between this project and the global library",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 's', section: :rules) { |ctx| ctx.rewriter_scope_toggle; nil }
      r.register Verb::Definition.new(
        "rewriter.toggle-default", "Enable/disable everywhere",
        "Flip a global rule's default — what every project that hasn't overridden it follows",
        Verb::Scope::Rewriter, available: global_rule, mnemonic: 'g', section: :rules) { |ctx| ctx.rewriter_toggle_default; nil }
    end
  end
end
