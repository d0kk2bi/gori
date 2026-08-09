require "../spec_helper"

# The "dark AND light themes both stay readable" requirement, machine-checked.
#
# A Colormarker `full` rule tints the row's whole background, and the row's foregrounds are NOT
# re-picked for contrast: `Theme.muted` (TIME/TYPE/SIZE/DUR), `Theme.method_color` (METHOD) and
# `FlowStatus.cell` (STA) each carry a MEANING the renderer cannot re-choose without destroying
# it. So the guarantee runs the other way round — bound how far the band moves and the existing
# semantic foregrounds stay valid on it. That bound is `Theme::ROW_TINT_LUMA`, and this file is
# the only thing holding it across all 30 built-in palettes in both polarities.
describe "Theme.row_tint" do
  colors = %w[red orange yellow green blue purple]
  # The three bands a History row can already have: canvas, marked, selected+focused.
  bands = -> { {"bg"            => Gori::Tui::Theme.bg,
                "selection_dim" => Gori::Tui::Theme.selection_dim,
                "accent_bg"     => Gori::Tui::Theme.accent_bg} }

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

  # Every built-in name must resolve to the palette field it NAMES, on every theme — the reason
  # the set is these six and not an arbitrary eight.
  #
  # Asserted against the field rather than against the fallback, which is what a "did it fall
  # through" test needs now that there is one string-keyed resolver: its fallback is `yellow`,
  # and `yellow` is itself one of the six. "None of them equals the fallback" could no longer
  # tell a correct `yellow` from a `blue` that silently fell through to it — the exact
  # regression this case exists to catch. Naming the expected field per label is exact, and it
  # also pins WHICH field each word borrows (`blue`/`purple` take the two syntax hues, which is
  # where the palette keeps them).
  it "resolves every built-in MarkerColor to the palette field it names" do
    before = Gori::Tui::Theme.active_name
    begin
      Gori::Tui::Theme::BUILTIN_THEMES.each_key do |theme|
        Gori::Tui::Theme.apply(theme)
        expected = {
          "red"    => Gori::Tui::Theme.red,
          "orange" => Gori::Tui::Theme.orange,
          "yellow" => Gori::Tui::Theme.yellow,
          "green"  => Gori::Tui::Theme.green,
          "blue"   => Gori::Tui::Theme.syn_header,
          "purple" => Gori::Tui::Theme.syn_literal,
        }
        # The enum is the vocabulary, so the table above must cover it exactly — a seventh
        # member added without a hue here fails rather than going unchecked.
        Gori::Store::MarkerColor.values.map(&.label).sort!.should eq(expected.keys.sort!)
        expected.each do |label, hue|
          Gori::Tui::Theme.mark_color(label).should eq(hue), "#{theme}: #{label}"
        end
      end
    ensure
      Gori::Tui::Theme.apply(before)
    end
  end
end
