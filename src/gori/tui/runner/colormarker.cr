# Colormarker (History row-colour rules) — ExecContext verb implementations, reopens
# Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def colormarker_add : Nil
    colormarker_controller.colormarker_add
  end

  def colormarker_edit : Nil
    colormarker_controller.colormarker_edit
  end

  def colormarker_toggle : Nil
    colormarker_controller.colormarker_toggle
  end

  def colormarker_delete : Nil
    colormarker_controller.colormarker_delete
  end

  def colormarker_move(dir : Int32) : Nil
    colormarker_controller.colormarker_move(dir)
  end

  def colormarker_duplicate : Nil
    colormarker_controller.colormarker_duplicate
  end

  def colormarker_reload : Nil
    colormarker_controller.colormarker_reload
  end

  # No sub-tab half here, unlike `rewriter_rule_selected?`. That predicate has to ask
  # `rules_sub?` because the Rewriter tab renders three different lists in one body and the
  # space menu would otherwise act on a row that is not on screen. Colormarker's body is one
  # list, always the one `selected_rule` names, so there is nothing further to gate on.
  def colormarker_rule_selected? : Bool
    colormarker_controller.rule_selected?
  end

  # The selected rule is a GLOBAL one — the gate for the verb that only means something for
  # the library half (flip the default everywhere).
  def colormarker_global_rule_selected? : Bool
    colormarker_controller.global_rule_selected?
  end

  def colormarker_scope_toggle : Nil
    colormarker_controller.colormarker_scope_toggle
  end

  def colormarker_toggle_default : Nil
    colormarker_controller.colormarker_toggle_default
  end
end
