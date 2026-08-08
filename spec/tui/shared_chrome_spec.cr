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

  it "leaves the ‹/› cycler to Frame.option_cycle" do
    # Three dialects had grown for one control: the full strip (four rule forms, byte-identical
    # private copies), the lit value alone (OAST provider, the Scope form's `kind:` row), and a
    # value with the cue in its own colour drawn on every row whether focused or not (Miner,
    # Sequencer, Probe active, Compact, Discover). The middle one is the costly one — a form
    # whose entire first question is "include or exclude?" showed only the current answer.
    #
    # Colormarker's colour row is the sole exception and draws its own: each option carries a
    # hue swatch, which no generic renderer can place. It is required to spell the cue the
    # same way, which is what this check enforces for it.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      next if File.basename(path) == "frame.cr"
      File.read(path).lines.each_with_index do |line, i|
        next unless line.includes?("‹/›")
        next unless line.includes?("screen.text")
        # The one hand-drawn cue left, and it must match `option_cycle`'s exactly.
        next if File.basename(path) == "colormarker_rule_overlay.cr" &&
                line.includes?(%[" ‹/›", Theme.muted, bg) if row_sel])
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

  describe ".option_cycle" do
    it "draws the whole strip when there is room for it" do
      # The point of a strip: the alternatives are visible without pressing anything.
      backend = MemoryBackend.new(60, 4)
      Frame.option_cycle(Screen.new(backend), 0, 0, 60, Theme.panel,
        "kind:", ["include", "exclude"], 0, false)
      backend.row(0).should contain("include")
      backend.row(0).should contain("exclude")
    end

    it "falls back to the chosen value alone when the strip will not fit" do
      # `MAX_REQ_CHOICES` is eight numbers plus `uncapped`; on a narrow card the strip would
      # run off the row. The fallback is a WIDTH decision made here, which is what lets every
      # caller use one renderer — the Miner and Sequencer configs used to hard-code it.
      backend = MemoryBackend.new(30, 4)
      opts = ["uncapped", "100", "250", "500", "1000", "2500", "5000", "10000"]
      Frame.option_cycle(Screen.new(backend), 0, 0, 30, Theme.panel,
        "max requests:", opts, 2, false)
      backend.row(0).should contain("250")
      backend.row(0).should_not contain("uncapped")
      backend.row(0).should_not contain("10000")
    end

    it "shows the ‹/› cue only while the row has focus" do
      # Several forms drew it on every row at once, which advertises keys that do nothing
      # unless that row is the selected one.
      focused = MemoryBackend.new(60, 4)
      Frame.option_cycle(Screen.new(focused), 0, 0, 60, Theme.panel,
        "kind:", ["include", "exclude"], 0, true)
      focused.row(0).should contain("‹/›")

      resting = MemoryBackend.new(60, 4)
      Frame.option_cycle(Screen.new(resting), 0, 0, 60, Theme.panel,
        "kind:", ["include", "exclude"], 0, false)
      resting.row(0).should_not contain("‹/›")
    end

    it "reserves room for the cue, so focusing a row cannot push the strip off the edge" do
      # A width that fits the strip but NOT the strip plus the cue must take the fallback,
      # or selecting the row would silently truncate the last option.
      opts = ["alpha", "bravo", "charlie"]
      # label 5 + 1, strip = 7 + 7 + 9 = 23 → 29; the cue is 4 more.
      backend = MemoryBackend.new(40, 4)
      Frame.option_cycle(Screen.new(backend), 0, 0, 31, Theme.panel,
        "kind:", opts, 1, true)
      backend.row(0).should contain("bravo")
      backend.row(0).should_not contain("charlie")
    end

    it "returns the x past what it drew, for a caller placing something after it" do
      # The Colormarker style row puts a live sample two cells past the cycler and used to
      # re-derive that x from the label width, the option padding and the cue width.
      backend = MemoryBackend.new(60, 4)
      stop = Frame.option_cycle(Screen.new(backend), 0, 0, 60, Theme.panel,
        "style:", ["full row", "strip"], 0, false)
      # "style:" (6) + 1 + " full row " (10) + " strip " (7) = 24
      stop.should eq(24)
    end
  end
end
