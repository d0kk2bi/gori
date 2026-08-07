require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def key(k : Termisu::Input::Key, shift = false) : Termisu::Event::Key
  mods = shift ? Termisu::Input::Modifier::Shift : Termisu::Input::Modifier::None
  Termisu::Event::Key.new(k, mods)
end

private def typing(ch : Char) : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: ch)
end

describe ColormarkerRuleOverlay do
  it "defaults a new rule to yellow, full-row, this project" do
    ov = ColormarkerRuleOverlay.adding
    ov.color.yellow?.should be_true
    ov.style.full?.should be_true # creation offers full even though PARSING falls back to strip
    ov.scope.project?.should be_true
    ov.condition.should be_empty
    ov.editing?.should be_false
    ov.edit_id.should be_nil
  end

  it "seeds from an existing rule and remembers the scope it was opened at" do
    rule = Gori::Store::ColorRule.new(7_i64, true, "status:5xx",
      Gori::Store::MarkerColor::Red, Gori::Store::MarkerStyle::Strip, "prod",
      scope: Gori::Store::RuleScope::Global)
    ov = ColormarkerRuleOverlay.editing(rule)
    ov.name.should eq("prod")
    ov.condition.should eq("status:5xx")
    ov.color.red?.should be_true
    ov.style.strip?.should be_true
    ov.scope.global?.should be_true
    ov.edit_id.should eq(7_i64)
    # The scope the form OPENED at, so a commit can tell an edit from a re-home.
    ov.edit_scope.should eq(Gori::Store::RuleScope::Global)
  end

  it "cycles colour and style with ←/→" do
    ov = ColormarkerRuleOverlay.adding
    2.times { ov.handle_key(key(Termisu::Input::Key::Down)) } # name → scope → colour
    ov.handle_key(key(Termisu::Input::Key::Right))
    ov.color.green?.should be_true # yellow → green
    ov.handle_key(key(Termisu::Input::Key::Left))
    ov.color.yellow?.should be_true
    ov.handle_key(key(Termisu::Input::Key::Down)) # → style
    ov.handle_key(key(Termisu::Input::Key::Right))
    ov.style.strip?.should be_true
  end

  # Validity lives on the engine so the TUI, CLI and MCP cannot disagree about what is legal.
  # These are the three refusals, each of which would otherwise fail SILENTLY.
  describe "#valid?" do
    it "refuses an empty condition" do
      ov = ColormarkerRuleOverlay.adding
      ov.valid?.should be_false
      ov.invalid_reason.should eq("enter a condition")
    end

    it "refuses a condition that matches every flow" do
      ov = ColormarkerRuleOverlay.new(match_filter: "host:")
      ov.valid?.should be_false
      ov.invalid_reason.should eq("this condition matches every flow")
    end

    it "refuses a QL field this backend never implements" do
      ov = ColormarkerRuleOverlay.new(match_filter: "size:>10000")
      ov.valid?.should be_false
      ov.invalid_reason.should contain("unknown field `size:`")
    end

    it "accepts a real condition" do
      ColormarkerRuleOverlay.new(match_filter: "status:5xx AND -host:cdn").valid?.should be_true
    end
  end

  describe "↹ on the condition row" do
    it "completes the token under the caret and stays on the row" do
      ov = ColormarkerRuleOverlay.new(match_filter: "sta")
      4.times { ov.handle_key(key(Termisu::Input::Key::Down)) } # → when:
      ov.handle_key(key(Termisu::Input::Key::Tab)).should eq(:stay)
      ov.condition.should eq("status:")
      # still on the condition row — one more character proves the focus did not move
      ov.handle_key(typing('5'))
      ov.condition.should eq("status:5")
    end

    # The other half, and the reason the arm is guarded rather than unconditional: with
    # nothing to complete ↹ must mean what it means on every other row.
    it "moves to the next field when there is nothing to complete" do
      ov = ColormarkerRuleOverlay.new(match_filter: "host:acme ")
      4.times { ov.handle_key(key(Termisu::Input::Key::Down)) }
      ov.handle_key(key(Termisu::Input::Key::Tab))
      ov.condition.should eq("host:acme ") # untouched
      # focus moved to Save, so ↵ commits rather than editing text
      ov.handle_key(key(Termisu::Input::Key::Enter)).should eq(:commit)
    end

    it "never claims ⇧↹, so there is always a keyboard way back up" do
      ov = ColormarkerRuleOverlay.new(match_filter: "sta")
      4.times { ov.handle_key(key(Termisu::Input::Key::Down)) }
      ov.handle_key(key(Termisu::Input::Key::BackTab, true))
      ov.condition.should eq("sta") # not completed
      # back on style:, so ←/→ cycles instead of typing
      ov.handle_key(key(Termisu::Input::Key::Right))
      ov.style.strip?.should be_true
    end
  end

  it "builds a candidate rule carrying every field" do
    ov = ColormarkerRuleOverlay.new(name: "n", match_filter: "host:a.test",
      color: "blue", style: "strip", scope: "global")
    cand = ov.candidate_rule
    cand.name.should eq("n")
    cand.match_filter.should eq("host:a.test")
    cand.color.blue?.should be_true
    cand.style.strip?.should be_true
    cand.scope.global?.should be_true
    cand.enabled?.should be_true # the preview asks "what WOULD this paint"
  end

  it "asks for a preview only when a match-relevant field changes" do
    ov = ColormarkerRuleOverlay.new(match_filter: "host:a")
    asked = 0
    ov.on_preview = ->(_r : Gori::Store::ColorRule) { asked += 1; "matches 1 of 1" }
    # The first keystroke primes the signature against the seeded condition — the form must
    # preview what it OPENED with, not wait for an edit.
    ov.handle_key(key(Termisu::Input::Key::Down))
    asked.should eq(1)

    # Navigating and cycling do not rescan: neither the colour nor the style is in the
    # signature, because neither changes which flows match.
    3.times { ov.handle_key(key(Termisu::Input::Key::Down)) } # scope → colour → style → when
    ov.handle_key(key(Termisu::Input::Key::Up))               # back to style
    ov.handle_key(key(Termisu::Input::Key::Right))            # cycle it
    asked.should eq(1)

    # Editing the condition does.
    ov.handle_key(key(Termisu::Input::Key::Down)) # → when
    ov.handle_key(typing('b'))
    ov.condition.should eq("host:ab")
    asked.should eq(2)
  end

  it "renders, and a click picks the row it drew" do
    ov = ColormarkerRuleOverlay.new(match_filter: "host:a.test")
    backend = MemoryBackend.new(100, 20)
    area = Rect.new(0, 0, 100, 20)
    ov.render(Screen.new(backend), area)
    backend.contains?("ADD COLOUR RULE").should be_true
    backend.contains?("colour:").should be_true
    backend.contains?("style:").should be_true
    backend.contains?("Save rule").should be_true

    box = ov.overlay_box(area).not_nil!
    # the colour row is the third (name, scope, colour)
    ov.handle_click(area, box.x + 5, box.y + 2 + ColormarkerRuleOverlay::ROW_COLOR).should eq(:stay)
    ov.handle_key(key(Termisu::Input::Key::Right))
    ov.color.green?.should be_true
    # a click on the Save row commits
    ov.handle_click(area, box.x + 5, box.y + 2 + ColormarkerRuleOverlay::ROW_SAVE).should eq(:commit)
  end

  it "shows the completable fields while the condition row has focus" do
    ov = ColormarkerRuleOverlay.adding
    4.times { ov.handle_key(key(Termisu::Input::Key::Down)) }
    backend = MemoryBackend.new(100, 20)
    ov.render(Screen.new(backend), Rect.new(0, 0, 100, 20))
    # No token to complete yet, so the band names what this backend actually knows — the
    # QL fields History's search bar accepts are a superset, and reaching for one is the
    # likely mistake.
    backend.contains?("host:").should be_true
    backend.contains?("proto:").should be_true
  end

  it "cancels on esc" do
    ColormarkerRuleOverlay.adding.handle_key(key(Termisu::Input::Key::Escape)).should eq(:cancel)
  end
end
