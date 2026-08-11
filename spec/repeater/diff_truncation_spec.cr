require "../spec_helper"

private alias Diff = Gori::Repeater::Diff

private def lines(n : Int32, tag : String) : Array(String)
  Array.new(n) { |i| "line #{i} #{tag}" }
end

# `Diff.lines` caps BOTH sides at MAX_LINES and its docstring makes noting that the caller's
# job ("the cap is noted by the caller"). Three callers forgot, so a change past the cut was
# absent from the diff AND from the count, and the CLI printed "no differences" — the answer
# an operator acts on. `truncated?` is that derivation with one home.
describe Gori::Repeater::Diff do
  describe ".truncated?" do
    it "is false while both sides fit" do
      Diff.truncated?(lines(Diff::MAX_LINES, "a"), lines(Diff::MAX_LINES, "a")).should be_false
    end

    # The ordinary shape: the new response is LONGER (an appended reflected payload, a stack
    # trace, an extra block). Those lines exist only in `b`, so only `b` is cut.
    it "is true when only the NEW side overruns" do
      Diff.truncated?(lines(10, "a"), lines(Diff::MAX_LINES + 1, "b")).should be_true
    end

    it "is true when only the ORIGINAL side overruns" do
      Diff.truncated?(lines(Diff::MAX_LINES + 1, "a"), lines(10, "b")).should be_true
    end
  end

  # The reason the note matters: a difference living past the cut is invisible to both the
  # diff and the count, so `change_count == 0` cannot be read as "the responses match".
  it "reports zero changes for a difference past the cap" do
    a = lines(Diff::MAX_LINES + 50, "same")
    b = a.dup
    b[Diff::MAX_LINES + 10] = "PAYLOAD REFLECTED HERE"

    Diff.change_count(Diff.lines(a, b)).should eq(0) # the cut hides it...
    Diff.truncated?(a, b).should be_true             # ...and this is what says so
  end

  it "still finds a difference that falls before the cap" do
    a = lines(Diff::MAX_LINES + 50, "same")
    b = a.dup
    b[10] = "PAYLOAD REFLECTED HERE"

    Diff.change_count(Diff.lines(a, b)).should be > 0
  end
end
