require "../../spec_helper"
require "json"

# `gori run colormarker` — the printed shapes. The commands themselves end in `abort`/`exit`
# and cannot be exercised from a spec, so what is pinned here is what an operator (or a script
# parsing `--format=json`) actually reads.
private def rule(id : Int64 = 1_i64, enabled = true, filter = "status:>=500",
                 color = "red",
                 style = Gori::Store::MarkerStyle::Full, name = "",
                 scope = Gori::Store::RuleScope::Project, overridden = false)
  Gori::Store::ColorRule.new(id, enabled, filter, color, style, name,
    scope: scope, overridden: overridden)
end

private def json_for(r : Gori::Store::ColorRule) : JSON::Any
  JSON.parse(JSON.build { |j| Gori::CLI::Run.colormarker_rule_json(j, r) })
end

describe "gori run colormarker — text rows" do
  it "leads with the scope letter, because that is half the rule's identity" do
    # The two stores number independently and both count from 1, so `#1` alone does not say
    # which rule the next command would address.
    row = Gori::CLI::Run.colormarker_rule_row(rule(name: "prod 5xx"))
    row.should start_with("P#1 [x] full  red   ")
    row.should contain("[prod 5xx]")
    row.should end_with("status:>=500")

    Gori::CLI::Run.colormarker_rule_row(rule(scope: Gori::Store::RuleScope::Global))
      .should start_with("G#1")
  end

  it "marks a global rule this project overrides, so two opposite rows cannot look alike" do
    r = rule(enabled: false, scope: Gori::Store::RuleScope::Global, overridden: true)
    row = Gori::CLI::Run.colormarker_rule_row(r)
    row.should start_with("G*#1 [ ]")
  end

  it "names an empty condition rather than printing a blank tail" do
    # The parser tolerates one already on disk (creation refuses to make one), and a row that
    # simply ended after the colour would read as a formatting bug rather than a real rule.
    Gori::CLI::Run.colormarker_rule_row(rule(filter: "")).should end_with("(every flow)")
  end

  it "aligns the style and colour columns so the conditions line up down the list" do
    a = Gori::CLI::Run.colormarker_rule_row(rule(filter: "host:a",
      color: "red", style: Gori::Store::MarkerStyle::Full))
    b = Gori::CLI::Run.colormarker_rule_row(rule(filter: "host:b",
      color: "orange", style: Gori::Store::MarkerStyle::Strip))
    a.index("host:a").should eq(b.index("host:b"))
  end
end

describe "gori run colormarker — JSON" do
  it "uses the same `when` key settings.json writes and the MCP tools accept" do
    o = json_for(rule(name: "n"))
    o["when"].as_s.should eq("status:>=500")
    o["color"].as_s.should eq("red")
    o["style"].as_s.should eq("full")
    o["scope"].as_s.should eq("project")
    o["enabled"].as_bool.should be_true
    o["name"].as_s.should eq("n")
  end

  # A project rule has ONE state. Printing two fields for it would invite the reader to look
  # for a difference that cannot exist.
  it "omits the override pair for a project rule" do
    o = json_for(rule)
    o.as_h.has_key?("overridden").should be_false
    o.as_h.has_key?("default_enabled").should be_false
  end

  it "carries both states for a global rule, where they can differ" do
    before = Gori::Settings.colormarker_rules
    begin
      Gori::Settings.colormarker_rules = [
        Gori::Settings::ColormarkerRule.new(4_i64, true, "", "host:cdn", "blue", "strip"),
      ]
      # enabled: the EFFECTIVE state here (off) · default_enabled: what the library says (on)
      o = json_for(rule(id: 4_i64, enabled: false,
        scope: Gori::Store::RuleScope::Global, overridden: true))
      o["enabled"].as_bool.should be_false
      o["overridden"].as_bool.should be_true
      o["default_enabled"].as_bool.should be_true
    ensure
      Gori::Settings.colormarker_rules = before
    end
  end
end
