require "./screen"
require "./theme"

module Gori::Tui
  # Shared brand mark (project picker hero + Help → About). The art block is a
  # fixed multi-line figure; ink extent (leftmost stroke, inked width) drives
  # optical centering so the visible shape — not its leading spaces — is centred.
  module Brand
    # The interlocked rings of the gori logo (docs/static/images/gori.svg), hand
    # drawn at 24 cells over 11 rows. A terminal cell is about half as wide as it
    # is tall, so that reads as a roughly square figure — the mark's own artwork is
    # 1365×1193 (1.14:1), close enough that it reads as the logo rather than a
    # stretched copy.
    #
    # Size is set by the top arc, not by overall detail. What makes this read as a
    # ring is that its outer contour closes: a 20×9 cut fit in more terminals but
    # left the upper-left arc a lone floating cell with gaps either side, and a
    # broken arc reads as debris, not as a loop. 24 columns is the narrowest the
    # arc stays connected at. The interior is left empty for the same reason the
    # contour matters: the logo's inner highlights are thinner than a cell here,
    # so drawing them puts loose specks inside the ring and weakens the loop.
    #
    # Going wider costs more than it buys — a 30×15 version does resolve those
    # highlights, but only barely, and `art_shown?` is a cliff rather than a slope:
    # its floor would rise to 33 rows, above a default 80×24 or any split pane, so
    # those terminals lose the mark entirely instead of getting a smaller one.
    # Here the gate is 29 rows / 30 cols — see ProjectPicker.art_shown?.
    #
    # The figure is two rings — a big tilted ellipse and a flat one lying across
    # the bottom, its tips curling up either side — and at this size they only
    # read as two if they differ. So the ART glyph carries ring membership: `█`
    # is the near ring, `▒` the far one. `ink` turns that into what actually gets
    # painted; nothing draws ART's characters directly.
    #
    # Every glyph must measure one cell (see spec/tui/brand_art_spec.cr): the
    # draw places glyph N of a line at column N, so a two-cell grapheme would
    # shear its row and pull the rings apart.
    ART = [
      "            ███████",
      "         ██       ███",
      "     ████████     ████",
      "   ███            ████",
      "   ███           ████",
      "   ███          ████ ▒",
      " ▒ █████      █████  ▒▒",
      "▒▒  ██████  ██████    ▒▒",
      " ▒▒▒  ██████████    ▒▒▒",
      " █████████████ ▒▒▒▒▒▒▒▒",
      "   ███████   ▒▒▒▒▒▒▒▒",
    ]

    # The far ring's marker, and how far its colour sits toward the canvas.
    FAR_RING     = '▒'
    FAR_RING_MIX = 0.58

    ART_H     = ART.size
    ART_LEFT  = ART.min_of { |line| line.size - line.lstrip.size }
    ART_INK_W = ART.max_of(&.rstrip.size) - ART_LEFT
    # Narrowest width that still seats the figure. Below it `art_origin_x` clamps
    # to 0 and the block's right edge runs off the pane, so this is the floor
    # every surface gates on — derived, because the figure gets redrawn and a
    # hardcoded column count silently stops matching it.
    ART_MIN_W = ART_INK_W + 2 * ART_LEFT

    AUTHOR  = "hahwul (Hwan Lee)"
    BYLINE  = "made by #{AUTHOR}"
    TAGLINE = "Hack from the terminal."

    # What an ART cell paints: both rings are solid blocks, the far one dimmed
    # toward the canvas so the interlock reads as depth rather than as one blob.
    #
    # The dim is COLOUR, not a lighter glyph. Painting `▒` literally renders it
    # as a dither pattern (a checkerboard in Menlo), and on a stroke one or two
    # cells thick that reads as texture rather than distance — the same reason
    # the mark is solid `█` and the scatter lives in the picker's entrance
    # instead (see ART_NOISE there). The pattern is font-dependent too, where a
    # blend of the palette's own colours is not.
    #
    # Every draw resolves its cells here, so the picker hero and Help → About
    # cannot disagree about the figure — which is exactly how the picker once
    # ended up painting ART as a plain silhouette while About drew the mark.
    def self.ink(ch : Char, fg : Color) : {Char, Color}
      return {'█', Theme.blend(fg, Theme.bg, FAR_RING_MIX)} if ch == FAR_RING
      {ch, fg}
    end

    # Static gilded art (no entrance animation). Defaults to the theme's gold
    # (focus_gold: logo-sampled champagne gold on dark, deepened logo gold on
    # light), so the mark reads as the real brand gold in every palette.
    # `origin_x` is the absolute column for glyph col 0 of each ART line
    # (includes the art's leading spaces).
    def self.draw_art(screen : Screen, origin_x : Int32, y : Int32,
                      *, fg : Color = Theme.focus_gold) : Nil
      ART.each_with_index do |line, i|
        line.each_char_with_index do |ch, col|
          next if ch == ' '
          glyph, colour = ink(ch, fg)
          screen.cell(origin_x + col, y + i, glyph, colour, Theme.bg, attr: Attribute::Bold)
        end
      end
    end

    # Horizontal origin so the inked figure is centred within `width` starting at `x0`.
    def self.art_origin_x(x0 : Int32, width : Int32) : Int32
      x0 + {(width - ART_INK_W) // 2 - ART_LEFT, 0}.max
    end
  end
end
