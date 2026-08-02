require "json"
require "../store/models"

# REWRITER section: the Rewriter tab's named rule presets. See settings.cr for the
# module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # A Match & Replace rule saved under a name, reusable in every project (settings.json
  # `rewriter.presets`). Same RECIPE-vs-MATERIAL split the Decoder's named chains rest on
  # (see settings/decoder.cr): "strip the CSP header on *.corp.internal" is tool config an
  # operator re-uses on every engagement, while WHICH rules are live — and the traffic they
  # rewrote — is project data and stays in the project DB (`match_rules`).
  #
  # Deliberately a copy of the rule's FIELDS, not a reference to a row: a preset must
  # survive the project it was lifted from being deleted, so it carries no id and no
  # `position` (apply order is a property of a project's list, not of one saved rule) and
  # no `enabled` (loading appends a live rule, exactly like Duplicate does).
  #
  # The enum fields are stored as their `label` strings — the same vocabulary `gori run
  # rewriter` and the MCP rule tools already speak — so a hand-edited settings.json reads
  # the way the CLI prints.
  record RulePreset,
    id : String,     # random hex token assigned on creation (stable across renames)
    name : String,   # the operator-facing label; unique by convention (save overwrites)
    target : String, # Store::RuleTarget label — "request" | "response"
    part : String,   # Store::RulePart label — "head" | "body" | "ws"
    pattern : String,
    replacement : String,
    op : String,          # Store::RuleOp label — "replace" | "add_header" | ... | "short_circuit"
    match_kind : String,  # Store::MatchKind label — "literal" | "regex"
    host : String,        # host glob ("" = every host)
    body_file : String do # ShortCircuit stub path ("" = inline body in `replacement`)
    # The preset as the rule it would become — `id: 0` and `enabled: true` because neither
    # is the preset's to know: an id belongs to the project row this is not yet, and a rule
    # added from the library goes live exactly like Duplicate's does.
    #
    # `from_label` RAISES on an unknown label and that is safe here: a preset only reaches
    # memory through `parse_rewriter_presets`, which clamps all four fields to their allowed
    # sets, or through `save_rewriter_preset`, which is handed a live rule's own `.label`.
    # The clamp at the parse boundary is what makes this total.
    def to_rule : Store::MatchRule
      Store::MatchRule.new(0_i64, true,
        Store::RuleTarget.from_label(target), Store::RulePart.from_label(part),
        pattern, replacement,
        Store::RuleOp.from_label(op), Store::MatchKind.from_label(match_kind),
        name, host, body_file)
    end
  end

  class_property rewriter_presets : Array(RulePreset) = [] of RulePreset

  RULE_PRESET_TARGETS = %w[request response]
  RULE_PRESET_PARTS   = %w[head body ws]
  RULE_PRESET_OPS     = %w[replace add_header set_header remove_header short_circuit]
  RULE_PRESET_KINDS   = %w[literal regex]

  # Tolerant preset parse: a non-array (or absent) node keeps the current value; entries
  # missing id/name/pattern are dropped (a rule with no pattern can never match, and
  # `Rules#add` refuses it anyway); the four enum fields are clamped to their allowed sets.
  #
  # Clamping rather than `from_label` is the point: those raise on an unknown label, and a
  # single typo in a hand-edited settings.json would take the whole file down through
  # `load`'s blanket rescue — resetting theme, hotkeys and every other section to factory
  # defaults. Mirrors parse_scan_rules.
  private def self.parse_rewriter_presets(node : JSON::Any?) : Array(RulePreset)
    arr = node.try(&.as_a?)
    return rewriter_presets unless arr
    presets = [] of RulePreset
    arr.each do |e|
      next unless o = e.as_h?
      id = o["id"]?.try(&.as_s?)
      name = o["name"]?.try(&.as_s?)
      pattern = o["pattern"]?.try(&.as_s?)
      next if id.nil? || id.empty? || name.nil? || name.empty? || pattern.nil? || pattern.empty?
      presets << RulePreset.new(
        id, name,
        clamp_field(o["target"]?.try(&.as_s?), RULE_PRESET_TARGETS, "request"),
        clamp_field(o["part"]?.try(&.as_s?), RULE_PRESET_PARTS, "head"),
        pattern,
        o["replacement"]?.try(&.as_s?) || "",
        clamp_field(o["op"]?.try(&.as_s?), RULE_PRESET_OPS, "replace"),
        clamp_field(o["match_kind"]?.try(&.as_s?), RULE_PRESET_KINDS, "literal"),
        o["host"]?.try(&.as_s?) || "",
        o["body_file"]?.try(&.as_s?) || "")
    end
    presets
  end

  # --- global rule-preset library CRUD -------------------------------------------------
  # Save under `name`, REPLACING any preset already holding it (the TUI prompts with the
  # rule's own name, so re-saving an edited rule must update rather than fork a duplicate
  # the picker then shows twice). Returns whether the write reached disk AND whether the
  # name already existed, so the caller can toast "saved" vs "updated" honestly.
  def self.save_rewriter_preset(name : String, target : String, part : String, pattern : String,
                                replacement : String, op : String, match_kind : String,
                                host : String, body_file : String) : {Bool, Bool}
    prior = rewriter_presets.find { |p| p.name == name }
    # Keep the id across an overwrite: it is the preset's identity, and a caller holding
    # one (a future delete/reorder) must not have it change under an in-place update.
    id = prior.try(&.id) || Random::Secure.hex(4)
    kept = rewriter_presets.reject { |p| p.name == name }
    self.rewriter_presets = kept + [RulePreset.new(id, name, target, part, pattern,
      replacement, op, match_kind, host, body_file)]
    {save, !prior.nil?}
  end

  def self.delete_rewriter_preset(id : String) : Bool
    self.rewriter_presets = rewriter_presets.reject { |p| p.id == id }
    save
  end

  # Omit the whole block when there are no presets, so an untouched OR cleared Rewriter
  # library never writes a "rewriter" section.
  private def self.serialize_rewriter(j : JSON::Builder) : Nil
    return if rewriter_presets.empty?
    j.field "rewriter" do
      j.object do
        j.field "presets" do
          j.array do
            rewriter_presets.each do |p|
              j.object do
                j.field "id", p.id
                j.field "name", p.name
                j.field "target", p.target
                j.field "part", p.part
                j.field "pattern", p.pattern
                j.field "replacement", p.replacement
                j.field "op", p.op
                j.field "match_kind", p.match_kind
                j.field "host", p.host
                j.field "body_file", p.body_file
              end
            end
          end
        end
      end
    end
  end
end
