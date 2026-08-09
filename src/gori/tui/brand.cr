require "./screen"
require "./theme"

module Gori::Tui
  # Shared brand mark (project picker hero + Help → About). The art block is a
  # fixed multi-line figure; ink extent (leftmost stroke, inked width) drives
  # optical centering so the visible shape — not its leading spaces — is centred.
  module Brand
    # The interlocked rings of the gori logo (docs/static/images/gori.svg), hand
    # drawn at 32 cells over 16 rows. A terminal cell is about half as wide as it
    # is tall, so that reads as a roughly square figure — the mark's own artwork is
    # 1365×1193 (1.14:1), close enough that it reads as the logo rather than a
    # stretched copy. It is deliberately big: at the ~20×9 the mark was drawn at
    # before, the two rings collapsed into a blob and stopped reading as rings.
    # The size is what costs the height gate — see ProjectPicker.art_shown?.
    #
    # Solid blocks, not scattered glyphs. The strokes are one or two cells thick,
    # so any mix of glyph weights reads as broken lines rather than arcs, and `█`
    # is the one glyph whose ink and advance are identical in every font — which
    # also keeps this the same mark as the SVG/favicon everywhere else. The noise
    # belongs in the picker's entrance instead (see ART_NOISE there).
    #
    # Every glyph must measure one cell (see spec/tui/brand_art_spec.cr): the
    # draw places glyph N of a line at column N, so a two-cell grapheme would
    # shear its row and pull the rings apart.
    ART = [
      "                    █████",
      "               ██████ ██████",
      "            ███          █████",
      "         ███████          ████",
      "      ████       █████    █████",
      "     ███               █ ██████",
      "    ████           ██   ██████",
      "    █████              ██████",
      "  █ ██████            ██████  █",
      " ██  ██████         ███████   ███",
      " ██   ████████    ████████  █  ██",
      " ██     ████████████████       ██",
      " ████     ████████████      █████",
      "  █████████████████  ███████████",
      "   █████████████  █████████████",
      "                       ████",
    ]

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
          screen.cell(origin_x + col, y + i, ch, fg, Theme.bg, attr: Attribute::Bold)
        end
      end
    end

    # Horizontal origin so the inked figure is centred within `width` starting at `x0`.
    def self.art_origin_x(x0 : Int32, width : Int32) : Int32
      x0 + {(width - ART_INK_W) // 2 - ART_LEFT, 0}.max
    end
  end
end
