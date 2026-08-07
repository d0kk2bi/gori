require "json"
require "../store/models"

# COLORMARKER section: the GLOBAL half of the History row-colour rule set. See settings.cr for
# the module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # A colour rule that lives in settings.json (`colormarker.rules`) instead of a project DB,
  # and therefore applies in EVERY project. The counterpart to a `color_rules` row; both fold
  # into the runtime `Store::ColorRule` list through `Colormarker.merged`, exactly the way
  # `Settings::RewriterRule` and `match_rules` fold into `Rules.merged`.
  #
  # The enum fields are stored as their `label` strings — the vocabulary `gori run colormarker`
  # and the MCP colour-rule tools already speak — so a hand-edited settings.json reads the way
  # the CLI prints.
  record ColormarkerRule,
    id : Int64,            # monotonic, from `colormarker_next_rule_id`; never reused
    enabled : Bool,        # the DEFAULT across projects; a project may override it
    name : String,         # the operator-facing label ("" = unnamed)
    match_filter : String, # an InterceptFilter source string
    color : String,        # Store::MarkerColor label
    style : String do      # Store::MarkerStyle label — "full" | "strip"
    # The rule as History sees it in one project: `enabled` is the EFFECTIVE state there (this
    # rule's default unless the project overrode it) and `overridden` says which of the two it
    # is, so the list row can mark it.
    #
    # Both `from_label`s are tolerant, so this is total for any string that reaches memory.
    def to_rule(enabled : Bool = @enabled, overridden : Bool = false) : Store::ColorRule
      Store::ColorRule.new(id, enabled, match_filter,
        Store::MarkerColor.from_label(color), Store::MarkerStyle.from_label(style),
        name, scope: Store::RuleScope::Global, overridden: overridden)
    end
  end

  class_property colormarker_rules : Array(ColormarkerRule) = [] of ColormarkerRule

  # The next global rule id, monotonic and NEVER reused — same reasoning as
  # `rewriter_next_rule_id`: handing a deleted rule's number to the next one created would
  # leave a project silently overriding a rule it never saw, because the override lives in a
  # different file this process may never open again.
  #
  # Counts from ONE, so 0 is free to mean "the write did not commit" in
  # `add_colormarker_rule`'s answer — the contract `Store#insert_color_rule` also has.
  class_property colormarker_next_rule_id : Int64 = 1_i64

  COLORMARKER_COLORS = %w[red orange yellow green blue purple]
  COLORMARKER_STYLES = %w[full strip]

  private def self.parse_colormarker(node : JSON::Any) : Nil
    self.colormarker_rules = parse_colormarker_rules(node["rules"]?)
    stored = node["next_rule_id"]?.try(&.as_i64?) || 0_i64
    # Never go BACKWARDS from the ids actually present, whatever the file says.
    self.colormarker_next_rule_id = {stored, (colormarker_rules.max_of?(&.id) || 0_i64) + 1, 1_i64}.max
  end

  # Tolerant global-rule parse: a non-array (or absent) node keeps the current value; the two
  # enum fields are clamped to their allowed sets rather than parsed with `from_label`, so a
  # typo in a hand-edited settings.json cannot take the whole file down through `load`'s
  # blanket rescue.
  #
  # TWO deliberate departures from `parse_rewriter_rules`, both load-bearing:
  #
  # 1. An entry with an EMPTY `match_filter` is KEPT, where a rewriter entry with an empty
  #    `pattern` is dropped. The reasoning inverts: a rewrite rule with no pattern can never
  #    match, but `InterceptFilter::EMPTY` matches EVERYTHING — so this is a legal, if unwise,
  #    "paint every row" rule, and dropping it would delete a rule its author can see in their
  #    own file. `Colormarker#add` refuses to CREATE one; the parser only has to not lose it.
  #
  # 2. A missing `enabled` reads as TRUE, where a rewriter rule reads FALSE. That rule exists
  #    because a rewrite rule modifies live traffic in every project, so "on" is the one
  #    direction a malformed entry may not default to. Colormarker touches no traffic: its
  #    failure-on-false is a hand-written rule that silently never appears (and an operator who
  #    concludes the feature is broken), its failure-on-true is one coloured row. Pinned by a
  #    spec, because the two parsers side by side invite a "consistency" fix.
  private def self.parse_colormarker_rules(node : JSON::Any?) : Array(ColormarkerRule)
    arr = node.try(&.as_a?)
    return colormarker_rules unless arr
    list = [] of ColormarkerRule
    seen = Set(Int64).new
    arr.each do |e|
      next unless o = e.as_h?
      list << ColormarkerRule.new(
        claim_id(o["id"]?.try(&.as_i64?), seen),
        o["enabled"]?.try(&.as_bool?) != false,
        o["name"]?.try(&.as_s?) || "",
        o["when"]?.try(&.as_s?) || "",
        clamp_field(o["color"]?.try(&.as_s?), COLORMARKER_COLORS, "yellow"),
        clamp_field(o["style"]?.try(&.as_s?), COLORMARKER_STYLES, "full"))
    end
    list
  end

  # --- global rule CRUD -----------------------------------------------------------------
  # Each mutation rewrites the array and persists via `save` (atomic + 3-way merge). The array
  # ORDER is the precedence order among global rules — the first enabled match paints the row —
  # which is why add appends and move swaps.

  # Returns the new rule's id, or 0 when the write did not reach disk.
  def self.add_colormarker_rule(match_filter : String, color : String, style : String,
                                name : String = "", enabled : Bool = true) : Int64
    id = colormarker_next_rule_id
    self.colormarker_next_rule_id = id + 1
    self.colormarker_rules = colormarker_rules + [ColormarkerRule.new(id, enabled, name, match_filter, color, style)]
    save ? id : 0_i64
  end

  # Field update only — `enabled` is untouched, because it is the rule's default across
  # projects and an edit made in one of them is not a statement about the others.
  def self.update_colormarker_rule(id : Int64, match_filter : String, color : String,
                                   style : String, name : String = "") : Bool
    found = false
    self.colormarker_rules = colormarker_rules.map do |r|
      next r unless r.id == id
      found = true
      ColormarkerRule.new(id, r.enabled, name, match_filter, color, style)
    end
    found && save
  end

  # The rule's DEFAULT state, which every project without an override follows.
  def self.set_colormarker_rule_enabled(id : Int64, enabled : Bool) : Bool
    found = false
    self.colormarker_rules = colormarker_rules.map do |r|
      next r unless r.id == id
      found = true
      r.copy_with(enabled: enabled)
    end
    found && save
  end

  def self.delete_colormarker_rule(id : Int64) : Bool
    kept = colormarker_rules.reject { |r| r.id == id }
    return false if kept.size == colormarker_rules.size
    self.colormarker_rules = kept
    save
  end

  # Swap the rule one slot earlier (dir < 0) / later (dir > 0) among the GLOBAL rules. Never
  # across the scope boundary: "past the last global rule" is not a position, it is a scope
  # change, which is its own action.
  def self.move_colormarker_rule(id : Int64, dir : Int32) : Bool
    list = colormarker_rules.dup
    i = list.index { |r| r.id == id }
    return false unless i
    j = i + (dir < 0 ? -1 : 1)
    return false if j < 0 || j >= list.size
    list[i], list[j] = list[j], list[i]
    self.colormarker_rules = list
    save
  end

  # Omit the whole block when there is nothing to say, so an untouched install never writes a
  # "colormarker" section. The counter is written even with an empty list — it is what keeps a
  # deleted rule's id from being handed out again after the last rule is removed.
  private def self.serialize_colormarker(j : JSON::Builder) : Nil
    return if colormarker_rules.empty? && colormarker_next_rule_id <= 1
    j.field "colormarker" do
      j.object do
        j.field "next_rule_id", colormarker_next_rule_id
        j.field "rules" do
          j.array do
            colormarker_rules.each do |r|
              j.object do
                j.field "id", r.id
                j.field "enabled", r.enabled
                j.field "name", r.name
                # "when", not "match_filter": the same key `gori run colormarker --format=json`
                # prints and the MCP tools accept, so one vocabulary spans all three surfaces.
                j.field "when", r.match_filter
                j.field "color", r.color
                j.field "style", r.style
              end
            end
          end
        end
      end
    end
  end
end
