require "../spec_helper"

private alias SW = Gori::Tui::SetupWizard

# The wizard's minimum terminal height used to be checked PER STEP, against each step's own
# `content_rows`. The steps don't agree — BIND needs 14 terminal rows, PET 13, REVIEW 15 — so a
# 14-row terminal rendered BIND, THEME and PET and then replaced REVIEW with "terminal too
# small". REVIEW is the only step that can commit, and input runs regardless of the render
# guard, so ↵ still saved from a screen that said it couldn't draw. `MIN_H` is now derived from
# the tallest step; these examples pin that derivation from BOTH sides, so a step that grows a
# row can't quietly push the real floor past the advertised one again.
describe Gori::Tui::SetupWizard do
  it "gives every fixed-layout step a card that fits at MIN_H" do
    {SW::BIND_ROWS, SW::PET_ROWS, SW::REVIEW_ROWS}.each do |rows|
      # `rows + 3` = top border + pad row + content + bottom border, which is exactly the
      # invariant render_* rely on: they draw at fixed offsets down to `box.y + 2 + rows - 1`.
      SW.card_h(SW::MIN_H, rows).should be >= rows + 3
    end
  end

  it "sets MIN_H no higher than the tallest step actually needs" do
    # One row below the floor the tallest step must NOT fit — otherwise MIN_H is padded and the
    # wizard turns away terminals it could have served.
    tallest = {SW::BIND_ROWS, SW::PET_ROWS, SW::REVIEW_ROWS}.max
    SW.card_h(SW::MIN_H - 1, tallest).should be < tallest + 3
  end

  it "advertises the width that Layout.usable? actually rejects at" do
    # `fits?` takes its width test entirely from Layout.usable?; MIN_W exists only to be the
    # number in the on-screen "min 40x15" message. So the pair that matters is: the advertised
    # width is accepted, and one column under it is not. The second assertion is the load-bearing
    # one — it fails if Layout's floor moves and the message is left promising a size that no
    # longer works.
    Gori::Tui::Layout.usable?(SW::MIN_W, SW::MIN_H).should be_true
    Gori::Tui::Layout.usable?(SW::MIN_W - 1, SW::MIN_H).should be_false
  end
end
