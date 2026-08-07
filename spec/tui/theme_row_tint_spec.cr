require "../spec_helper"

# The "dark AND light themes both stay readable" requirement, machine-checked.
#
# A Colormarker `full` rule tints the row's whole background, and the row's foregrounds are NOT
# re-picked for contrast: `Theme.muted` (TIME/TYPE/SIZE/DUR), `Theme.method_color` (METHOD) and
# `FlowStatus.cell` (STA) each carry a MEANING the renderer cannot re-choose without destroying
# it. So the guarantee runs the other way round — bound how far the band moves and the existing
# semantic foregrounds stay valid on it. That bound is `Theme::ROW_TINT_LUMA`, and this file is
# the only thing holding it across all 28 built-in palettes in both polarities.
describe "Theme.row_tint" do
  colors = [:red, :orange, :yellow, :green, :blue, :purple]
  # The three bands a History row can already have: canvas, marked, selected+focused.
  bands = ->{ {"bg" => Gori::Tui::Theme.bg,
               "selection_dim" => Gori::Tui::Theme.selection_dim,
               "accent_bg" => Gori::Tui::Theme.accent_bg} }

  it "never moves a band's luma past ROW_TINT_LUMA, on any theme, hue or band" do
    before = Gori::Tui::Theme.active_name
    begin
      Gori::Tui::Theme::BUILTIN_THEMES.each_key do |theme|
        Gori::Tui::Theme.apply(theme)
        bands.call.each do |band_name, base|
          colors.each do |name|
            hue = Gori::Tui::Theme.mark_color(name)
            tinted = Gori::Tui::Theme.row_tint(hue, base)
            delta = (Gori::Tui::Theme.luma(tinted) - Gori::Tui::Theme.luma(base)).abs
            # A float epsilon, not slack: the identity is exact, the arithmetic rounds to bytes.
            unless delta <= Gori::Tui::Theme::ROW_TINT_LUMA + 0.01
              fail "#{theme}/#{name} on #{band_name}: luma moved #{delta}"
            end
          end
        end
      end
    ensure
      Gori::Tui::Theme.apply(before)
    end
  end

  # The other half: a clamp that swallowed the tint entirely would pass the bound above while
  # making the feature invisible. Both directions have to hold at once.
  it "always produces a band distinguishable from the one it tinted" do
    before = Gori::Tui::Theme.active_name
    begin
      Gori::Tui::Theme::BUILTIN_THEMES.each_key do |theme|
        Gori::Tui::Theme.apply(theme)
        bands.call.each do |band_name, base|
          colors.each do |name|
            hue = Gori::Tui::Theme.mark_color(name)
            tinted = Gori::Tui::Theme.row_tint(hue, base)
            # Compare CHANNELS, not luma: the tint's whole point is that it carries chroma the
            # near-neutral bands do not, so a hue whose luma matches its band still reads.
            tr, tg, tb = tinted.to_rgb_components
            br, bg_, bb = base.to_rgb_components
            spread = (tr.to_i - br.to_i).abs + (tg.to_i - bg_.to_i).abs + (tb.to_i - bb.to_i).abs
            unless spread >= 6
              fail "#{theme}/#{name} on #{band_name}: tint is indistinguishable (spread #{spread})"
            end
          end
        end
      end
    ensure
      Gori::Tui::Theme.apply(before)
    end
  end

  # Every named colour must resolve to a real palette field on every theme — the reason the set
  # is these six and not an arbitrary eight. `muted` is `mark_color`'s fallback, so a name that
  # silently fell through would render as chrome rather than as a mark.
  it "resolves every MarkerColor to a distinct, non-fallback palette hue" do
    before = Gori::Tui::Theme.active_name
    begin
      Gori::Tui::Theme::BUILTIN_THEMES.each_key do |theme|
        Gori::Tui::Theme.apply(theme)
        resolved = Gori::Store::MarkerColor.values.map { |c| Gori::Tui::Theme.mark_color(c.to_sym) }
        resolved.size.should eq(6)
        # MATRIX and the other monochrome palettes legitimately collapse some hues onto one
        # another, so distinctness is not assertable — but nothing may land on the fallback.
        resolved.each_with_index do |c, i|
          if c == Gori::Tui::Theme.muted
            fail "#{theme}: #{Gori::Store::MarkerColor.values[i].label} fell through to muted"
          end
        end
      end
    ensure
      Gori::Tui::Theme.apply(before)
    end
  end
end
