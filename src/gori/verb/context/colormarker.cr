# Colormarker (History row-colour rules) — verbs, reopens Gori::Verb::ExecContext (see
# verb/context.cr for the full facade and the class-reopening convention).
abstract class Gori::Verb::ExecContext
  # colormarker: the row-colour rule list. The body is a navigable list with no text pane and
  # no sub-tabs, so — unlike the Rewriter — there is only ONE focus area here, and these verbs
  # back both the space menu/palette and the list's own keys with nothing to partition.
  abstract def colormarker_add : Nil               # open the editor to add a rule
  abstract def colormarker_edit : Nil              # edit the selected rule
  abstract def colormarker_toggle : Nil            # enable/disable the selected rule HERE
  abstract def colormarker_delete : Nil            # delete the selected rule (confirms)
  abstract def colormarker_move(dir : Int32) : Nil # reorder ±1 — which changes WHICH rule wins
  abstract def colormarker_duplicate : Nil         # copy the selected rule
  abstract def colormarker_reload : Nil            # re-read rules from the DB (external edits)
  abstract def colormarker_rule_selected? : Bool   # a rule is selected (gates edit/delete/…)
  # The scope half (`Store::RuleScope`), identical in shape to the Rewriter's: a rule lives
  # either in this project or in the global library every project reads.
  abstract def colormarker_scope_toggle : Nil           # move the selected rule global ⇄ project
  abstract def colormarker_toggle_default : Nil         # flip a global rule's default everywhere
  abstract def colormarker_global_rule_selected? : Bool # the selection is a global rule
end
