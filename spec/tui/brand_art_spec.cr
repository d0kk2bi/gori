require "../spec_helper"

include Gori::Tui

# `Brand.draw_art` paints glyph N of an ART line at column N (`origin_x + col`), and
# `ART_LEFT`/`ART_INK_W` measure the figure in CHARACTERS. Both only hold while every
# glyph occupies exactly one cell. The picker's entrance substitutes ART_NOISE glyphs
# into those same cells, so the rule covers the scramble alphabet too — a two-cell
# grapheme in either place would shear its row and leave the ring open.
describe "Brand::ART" do
  it "is drawn entirely in single-cell glyphs" do
    Brand::ART.each_with_index do |line, row|
      line.each_char_with_index do |ch, col|
        Screen.draw_width(ch.to_s).should eq(1), "row #{row} col #{col}: #{ch.inspect} is not one cell"
      end
    end
  end

  it "scrambles the entrance through single-cell glyphs too" do
    ProjectPicker::ART_NOISE.each_with_index do |band, i|
      band.should_not be_empty
      band.each do |ch|
        Screen.draw_width(ch.to_s).should eq(1), "noise band #{i}: #{ch.inspect} is not one cell"
      end
    end
  end

  # The ink extent is what centres the mark over the wordmark; a line wider than the
  # measured extent would hang off the right edge of the reserved block.
  it "keeps every line inside the measured ink extent" do
    Brand::ART.each do |line|
      line.rstrip.size.should be <= Brand::ART_LEFT + Brand::ART_INK_W
      line.should eq(line.rstrip) # no trailing padding — rstrip drives the extent
    end
  end

  it "reports the figure's own geometry" do
    Brand::ART_H.should eq(Brand::ART.size)
    Brand::ART_LEFT.should eq(Brand::ART.min_of { |l| l.size - l.lstrip.size })
    Brand::ART_INK_W.should be > 0
  end

  # The mark gets redrawn, and a bigger figure eats the picker from both ends: it
  # pushes the card down onto the hint row and its own top row up off the screen.
  # `art_shown?` is the only thing holding that line, so sweep every terminal size
  # it says yes to and prove the whole stack still fits.
  it "leaves the picker card and the art itself on screen wherever art_shown? says yes" do
    shown = 0
    (10..80).each do |h|
      (30..200).each do |w|
        next unless ProjectPicker.art_shown?(w, h)
        shown += 1
        box, rows = ProjectPicker.card_metrics(w, h)
        art_top = box.y - 3 - Brand::ART_H - ProjectPicker::ART_GAP
        art_top.should be >= 0, "#{w}x#{h}: art starts at row #{art_top}"
        box.bottom.should be <= h - 2, "#{w}x#{h}: card bottom #{box.bottom} hits the hint row"
        box.right.should be <= w
        rows.should be >= 1
      end
    end
    shown.should be > 0 # the sweep has to actually reach the art, or it proves nothing
  end

  # The figure is drawn from origin_x with its own leading indentation, so the
  # rightmost inked column is ART_LEFT + ART_INK_W - 1 past it. ART_MIN_W is the
  # width at which that still lands inside the pane.
  it "seats the widest line at ART_MIN_W" do
    right = Brand.art_origin_x(0, Brand::ART_MIN_W) + Brand::ART_LEFT + Brand::ART_INK_W - 1
    right.should be <= Brand::ART_MIN_W - 1
  end
end
