require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/colormarker.cr — the Colormarker (History row-colour) tab's rule list.
private def in_colormarker(rule : Bool = false, global : Bool = false) : FakeExecContext
  ctx = FakeExecContext.new
  ctx.current_tab = :colormarker
  ctx.colormarker_rule_selected = rule
  ctx.colormarker_global_rule = global
  ctx
end

describe "Gori::Verbs.register_colormarker" do
  r = Gori::Verbs.registry

  it "gates every rule action on a SELECTED rule, but leaves add and reload open" do
    empty = in_colormarker
    picked = in_colormarker(rule: true)

    %w[colormarker.edit colormarker.toggle colormarker.delete colormarker.move-up
      colormarker.move-down colormarker.duplicate colormarker.scope].each do |id|
      r[id].available?(empty).should be_false
      r[id].available?(picked).should be_true
    end
    r["colormarker.add"].available?(empty).should be_true
    r["colormarker.reload"].available?(empty).should be_true
  end

  it "offers the default-flip only for a GLOBAL rule" do
    # A project rule has no default to disagree with — `x` IS its state.
    r["colormarker.toggle-default"].available?(in_colormarker(rule: true)).should be_false
    r["colormarker.toggle-default"].available?(in_colormarker(rule: true, global: true)).should be_true
  end

  it "still requires the Colormarker tab even with a rule selected" do
    # colormarker_rule_selected? is pane state that survives a tab switch, so the tab half of
    # the gate is what stops these firing from another tab's Body.
    ctx = FakeExecContext.new
    ctx.current_tab = :history
    ctx.colormarker_rule_selected = true
    ctx.colormarker_global_rule = true
    r["colormarker.edit"].available?(ctx).should be_false
    r["colormarker.add"].available?(ctx).should be_false
    r["colormarker.toggle-default"].available?(ctx).should be_false
  end

  it "moves a rule in PRECEDENCE order with a signed delta" do
    # Precedence IS the semantics of a colour rule set — the first enabled match paints the
    # row — so up/down must not share a sign.
    ctx = in_colormarker(rule: true)
    r["colormarker.move-up"].call(ctx)
    ctx.args_for(:colormarker_move).should eq(["-1"])
    ctx = in_colormarker(rule: true)
    r["colormarker.move-down"].call(ctx)
    ctx.args_for(:colormarker_move).should eq(["1"])
  end

  it "routes the remaining actions to their own intents" do
    {"colormarker.add"            => :colormarker_add,
     "colormarker.edit"           => :colormarker_edit,
     "colormarker.toggle"         => :colormarker_toggle,
     "colormarker.delete"         => :colormarker_delete,
     "colormarker.duplicate"      => :colormarker_duplicate,
     "colormarker.reload"         => :colormarker_reload,
     "colormarker.scope"          => :colormarker_scope_toggle,
     "colormarker.toggle-default" => :colormarker_toggle_default,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
  end

  # The boot-time guarantee. Unlike the Rewriter's, these verbs need no named `section:` —
  # there is one focus area, so a displayable view here is `common ∪ {}` and the ten letters
  # only have to be distinct among themselves. If a future verb collides,
  # `Registry#validate_menu_keys!` raises while BUILDING the registry above, so this file
  # would not even reach an example.
  it "derives ten distinct space-menu keys inside one displayable view" do
    keys = [] of Char
    r.each { |v| v.menu_key.try { |k| keys << k } if v.scope.colormarker? }
    keys.size.should eq(10)
    keys.uniq.size.should eq(10)
  end
end
