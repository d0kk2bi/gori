require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `frame.cr` owns the card chrome — the rounded card, the tee'd divider, the scroll gauge, the
# annotation that rides a top border. The workbench tabs (Repeater, Fuzzer, Discover, Miner,
# Sequencer, …) had always drawn through it. The policy and settings pages had not: they
# hand-rolled the same three devices per file, and the copies drifted.
#
# These examples pin the two drifts that were measurable in source, so the next card added to
# this family inherits the shared geometry instead of a fresh copy of it.
describe "shared card chrome" do
  root = File.join(__DIR__, "..", "..", "src", "gori", "tui")

  it "puts no hand-rolled border annotation where Frame.border_meta belongs" do
    # The tell: a `screen.text` positioned by `rect.right - meta.size - N` — the right-aligned
    # meta each card used to place itself. Six files carried one, with five different guard
    # constants (+10 / +14 / +16 / +18 / +20) for the same layout, so sibling cards dropped
    # their count at different widths. None of the numbers was derived from the title they
    # were protecting; `Frame.border_meta` derives it.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      next if File.basename(path) == "frame.cr"
      File.read(path).lines.each_with_index do |line, i|
        next unless line.includes?("screen.text")
        next unless line.matches?(/\.right\s*-\s*meta\./)
        # Only a TOP-BORDER annotation, which is what the helper owns: the y argument is the
        # card's own `.y`. A right-aligned meta on a LIST ROW (project_picker draws each
        # project's flow count that way) is a different device at a per-row `y`, and forcing it
        # through a border helper would be the opposite mistake.
        next unless line.matches?(/,\s*\w+\.y\s*,/)
        offenders << "#{File.basename(path)}:#{i + 1}"
      end
    end
    offenders.should be_empty
  end

  it "leaves the scroll affordance to Frame.scroll_gauge" do
    # The Settings theme list painted ▲ / ▼ / ↕ into its own last interior column — an
    # affordance no other list in gori had, which said "there is more" without saying how
    # much, and cost a column the swatch wanted. The gauge answers both on the hairline.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next unless line.includes?("screen.cell")
        next unless line.includes?("'▲'") || line.includes?("'▼'") || line.includes?("'↕'")
        offenders << "#{File.basename(path)}:#{i + 1}"
      end
    end
    offenders.should be_empty
  end
end

describe Gori::Tui::Frame do
  describe ".border_meta" do
    # 40 wide, title ` SCOPE ` from x+2 → the title ends at x + 2 + 5 + 2 = x + 9.
    card = Rect.new(0, 0, 40, 10)

    it "right-aligns the annotation two cells inside the card's right edge" do
      backend = MemoryBackend.new(40, 10)
      Frame.border_meta(Screen.new(backend), card, "SCOPE", "7 rules")
      # "7 rules" is 7 cells ending at x = 37, so it starts at 31 — two clear of the edge, which
      # is where `Frame.card` puts its right border and corner.
      backend.row(0)[31, 7].should eq("7 rules")
    end

    it "draws nothing rather than landing on the title" do
      # A card too narrow to hold both drops the meta — the title is the one that must survive,
      # since it says WHAT the card is. The hand-rolled versions clamped instead, which is how
      # a count could end up written over the title's last letters.
      backend = MemoryBackend.new(40, 10)
      narrow = Rect.new(0, 0, 14, 10)
      Frame.border_meta(Screen.new(backend), narrow, "HOST OVERRIDES", "12 entries")
      backend.contains?("12 entries").should be_false
    end

    it "ignores an empty annotation" do
      backend = MemoryBackend.new(40, 10)
      Frame.border_meta(Screen.new(backend), card, "SCOPE", "")
      backend.contains?("SCOPE").should be_false # nothing drawn at all — card() draws the title
    end
  end
end
