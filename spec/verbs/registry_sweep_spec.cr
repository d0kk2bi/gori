require "../spec_helper"
require "../support/fake_context"

# Whole-registry invariants over EVERY verb file under src/gori/verbs/, not just one.
# Kept out of the per-file specs on purpose: a failure here names the offending verb id,
# and filing it under any single register_* group would send the reader to the wrong file.
describe "Gori::Verbs.registry (every verb)" do
  r = Gori::Verbs.registry

  it "registers a non-trivial number of verbs" do
    # Guards the two sweeps below: if the registry ever came back empty (or nearly so),
    # `select`/`each` over it would assert nothing and both would pass vacuously.
    r.size.should be > 100
  end

  # A verb whose handler dispatches nothing is a dead palette/menu entry: it renders, it
  # fires, and nothing happens. Nothing in the type system catches that.
  it "dispatches at least one ExecContext intent per verb" do
    dead = r.select { |v| verb_intents(r, v.id).empty? }.map(&.id)
    dead.should be_empty
  end

  # available? runs on every keypress and on every palette / space-menu render, over a
  # context whose panes may be empty — a raise there takes the whole TUI down.
  it "answers available? on a bare context without raising, for every verb" do
    ctx = FakeExecContext.new
    answered = r.count { |v| !v.available?(ctx).nil? }
    answered.should eq(r.size)
  end

  # #442 made the History verbs act on N flows by widening what they TARGET, not by adding a
  # second set of ids. A `history.batch-delete` beside `history.delete` would be two
  # declarations of one feature — two menu rows, two keybindings to keep in sync, two places
  # to fix a bug (P1, one execution path). This is the cheap guard against that drifting back.
  it "has no parallel batch-* twin of an existing verb" do
    ids = r.map(&.id).to_set
    twins = ids.select do |id|
      parts = id.split('.', 2)
      parts.size == 2 && parts[1].starts_with?("batch-") &&
        ids.includes?("#{parts[0]}.#{parts[1].lchop("batch-")}")
    end
    twins.should be_empty
  end

  it "gives every verb a non-empty id, title and description" do
    # All three are user-visible in the palette; a blank one ships as an unlabelled row.
    r.each do |v|
      v.id.should_not be_empty
      v.title.should_not be_empty
      v.description.should_not be_empty
    end
  end
end
