require "../spec_helper"

include Gori::Tui

# Miss Ring's stand on the TUTORIAL (Tutorial.pet_place / .pet_band / .step_card).
#
# Unlike the picker — which centres a 50-column card and drops her when she doesn't fit
# beside it — the tour NARROWS its card to make room, because copying the picker's rule to
# a 78-column card would not have seated her until ~102 columns. These sweep the pair of
# rules together: the card's width and her stand are two halves of one decision, and the
# way this breaks is that they stop agreeing.
describe Gori::Tui::Tutorial do
  # The whole reason the band exists. 80x24 is the conventional terminal, and the tour's
  # own "too small" message names 80 as its floor — a guide mascot absent on exactly the
  # terminals new users run would have missed the point.
  it "seats her from 80 columns" do
    Tutorial.pet_place(80, 24).should_not be_nil
    Tutorial.pet_place(80, 16).should_not be_nil
    Tutorial.pet_place(120, 40).should_not be_nil
  end

  # Below ~52 columns step_card's 40-column floor wins and the card grows back over her
  # stand, so she stands down rather than painting over the mock.
  it "stands down when the card floor leaves her no room" do
    Tutorial.pet_place(50, 24).should be_nil
    Tutorial.pet_place(44, 24).should be_nil
  end

  # The sprite may never touch the card: she stands there for the whole tour, and the mock
  # shell is what the user is being taught to read. (Her bubble is another matter — it
  # floats over the card for the few seconds she is talking, exactly as it does over the
  # picker's card and a tab body in the session.)
  #
  # Measured against the rect PET.DRAW would paint, NOT against pet_place's return value.
  # Those are the same rect when she is seated, but sourcing it from the draw path is what
  # keeps this from being a restatement of pet_place's own guard — see the render-path
  # test below, which is the one that fails if render_pet stops consulting the gate.
  it "never overlaps the card at any size she appears at" do
    (16..60).each do |h|
      (40..200).each do |w|
        next unless Tutorial.pet_place(w, h) # the gate render_pet applies
        rect = Pet.place(Tutorial.pet_stage(w, h)).should_not be_nil
        box = Tutorial.step_card(w, h, Tutorial.pet_band(w, h))
        # Her plate claims a column either side of the sprite (Pet.draw), so the box that
        # actually gets painted is one wider on each side than `rect`.
        cols = (rect.x - 1) < box.right && (rect.right + 1) > box.x
        rows = rect.y < box.bottom && rect.bottom > box.y
        (cols && rows).should be_false
      end
    end
  end

  # THE RENDER-PATH DRIFT GUARD, and the reason the tour needs one the picker does not.
  #
  # Tutorial.pet_place is deliberately stricter than Pet.place: it stands her down at sizes
  # Pet.place will happily seat her at. Pet.draw only knows Pet.place, so render_pet has to
  # apply the stricter rule itself — and when it did not, she painted over the mock tab bar
  # across the whole 40..51-column band while every other example here still passed.
  #
  # This asserts the two rules disagree EXACTLY where the card would be hit: seated sizes
  # clear the narrowed card, stood-down sizes are precisely the ones that would not have.
  # That makes the gate load-bearing rather than decorative.
  it "stands down precisely at the sizes Pet.draw would paint over the card" do
    stood_down = 0
    (16..60).each do |h|
      (40..200).each do |w|
        next unless drawn = Pet.place(Tutorial.pet_stage(w, h)) # else Pet.draw paints nothing
        if Tutorial.pet_place(w, h)
          # Seated: the card was narrowed for her, so what Pet.draw paints clears it.
          Tutorial.step_card(w, h, Tutorial::PET_BAND).right.should be <= drawn.x - 1
        else
          # Stood down: had render_pet not gated, Pet.draw would have hit the card.
          stood_down += 1
          Tutorial.step_card(w, h, 0).right.should be > drawn.x - 1
        end
      end
    end
    # The band is real, not a rule that never fires — 40..51 columns at every height.
    stood_down.should be > 0
  end

  # …and the render path itself. render_pet hands Pet.draw whatever pet_draw_stage returns,
  # so asserting on that rect IS asserting on what gets painted: nil means Pet.draw is
  # never reached, and non-nil means the sprite Pet.draw derives from it clears the card.
  # This is the example that fails if the gate is dropped from render_pet.
  it "hands Pet.draw a stage only when the sprite it derives will clear the card" do
    (16..60).each do |h|
      (40..200).each do |w|
        stage = Tutorial.pet_draw_stage(w, h)
        if stage.nil?
          Tutorial.pet_place(w, h).should be_nil # nothing is drawn at all
          next
        end
        rect = Pet.place(stage).should_not be_nil # exactly what Pet.draw will paint
        box = Tutorial.step_card(w, h, Tutorial.pet_band(w, h))
        (rect.x - 1).should be >= box.right
        (rect.right + 1).should be <= w
      end
    end
  end

  it "stays inside the terminal" do
    (16..60).each do |h|
      (40..200).each do |w|
        next unless rect = Tutorial.pet_place(w, h)
        (rect.x - 1).should be >= 0
        (rect.right + 1).should be <= w
        rect.y.should be >= 0
      end
    end
  end

  # The two footer rows (h-2 hint, h-1 Prev/Next) are the tour's escape hatch — a mascot
  # parked on them would cover the one control that is never allowed to be unreachable.
  it "keeps clear of the footer rows" do
    (16..60).each do |h|
      (40..200).each do |w|
        next unless rect = Tutorial.pet_place(w, h)
        rect.bottom.should be <= h - Tutorial::FOOTER_ROWS
      end
    end
  end

  # A default install has her OFF, and must render the tour exactly as it did before she
  # existed. band: 0 is the code path that takes — assert it against the original formula
  # rather than against a snapshot, so a change to either side has to be deliberate.
  it "leaves the card untouched while she is off" do
    (16..60).each do |h|
      (40..200).each do |w|
        box = Tutorial.step_card(w, h, 0)
        cw = { {w - 4, Tutorial::CARD_W}.min, 40 }.max
        box.w.should eq(cw)
        box.x.should eq({(w - cw) // 2, 0}.max)
      end
    end
  end

  # …and with her on, the card gives up only her band — never more, and never so much that
  # it stops being able to hold a mock (step_card's own 40-column floor).
  it "narrows the card by her band and no further" do
    (16..60).each do |h|
      (40..200).each do |w|
        band = Tutorial.pet_band(w, h)
        next if band.zero?
        box = Tutorial.step_card(w, h, band)
        plain = Tutorial.step_card(w, h, 0)
        box.w.should be <= plain.w
        box.w.should be >= 40
        box.w.should be >= plain.w - Tutorial::PET_BAND
      end
    end
  end

  # Height is not hers to change: the band is a COLUMN reservation, and the tour's
  # "too small" guard tests step_card(w, h).h against MIN_CARD_H.
  it "never changes the card's height or vertical seat" do
    (16..60).each do |h|
      (40..200).each do |w|
        banded = Tutorial.step_card(w, h, Tutorial.pet_band(w, h))
        plain = Tutorial.step_card(w, h, 0)
        banded.h.should eq(plain.h)
        banded.y.should eq(plain.y)
      end
    end
  end
end
