require "../spec_helper"
require "../../src/gori/repeater/word_diff"

private alias WD = Gori::Repeater::WordDiff

# A side's pieces must always reassemble into the line they came from — the renderer draws
# them in order and nothing else supplies the gaps.
private def lossless(a : String, b : String)
  la, lb = WD.pieces(a, b)
  la.join(&.text).should eq(a)
  lb.join(&.text).should eq(b)
  {la, lb}
end

private def changed_text(pieces)
  pieces.select(&.changed).join(&.text)
end

describe Gori::Repeater::WordDiff do
  it "lights only the differing value of an otherwise identical JSON line" do
    la, lb = lossless(%({"role":"user","id":7}), %({"role":"admin","id":7}))
    changed_text(la).should eq("user")
    changed_text(lb).should eq("admin")
  end

  it "lights a replaced token and leaves the punctuation around it alone" do
    la, lb = lossless(%(Set-Cookie: sid=a1b2c3; Path=/), %(Set-Cookie: sid=z9y8x7; Path=/))
    changed_text(la).should eq("a1b2c3")
    changed_text(lb).should eq("z9y8x7")
  end

  it "marks an inserted run on the new side only" do
    la, lb = lossless("GET /a HTTP/1.1", "GET /a/b HTTP/1.1")
    changed_text(la).should eq("")
    changed_text(lb).should contain("b")
  end

  it "marks several scattered changes independently, not one span across the middle" do
    la, lb = lossless("a=1&b=2&c=3", "a=9&b=2&c=8")
    # The shared middle (`b=2`) must survive as unchanged between the two changes.
    la.count(&.changed).should be >= 2
    changed_text(la).should eq("13")
    changed_text(lb).should eq("98")
  end

  it "falls back to a whole-line highlight when a side has no shared tokens" do
    la, lb = lossless("aaa", "zzz")
    la.size.should eq(1)
    la[0].changed.should be_true
    lb[0].changed.should be_true
  end

  it "treats an empty side as an entire change rather than dividing by nothing" do
    la, lb = lossless("", "new line")
    la.size.should eq(1)
    lb[0].changed.should be_true
  end

  # The DP is O(m*n) and runs per VISIBLE row, so a minified body line has to opt OUT of
  # the intra-line pass rather than pay for it. Past the cap each side is one changed piece
  # — exactly what the row rendered before this existed.
  it "drops the intra-line pass past MAX_TOKENS instead of running the table" do
    a = (0..WD::MAX_TOKENS).map { |i| "k#{i}=v#{i}" }.join("&")
    b = a.sub("v0", "vX")
    la, lb = lossless(a, b)
    la.size.should eq(1)
    lb.size.should eq(1)
    la[0].changed.should be_true
  end

  it "keeps a non-ASCII run whole instead of slicing a codepoint" do
    la, lb = lossless("name=한글값", "name=다른값")
    la.join(&.text).valid_encoding?.should be_true
    changed_text(la).should_not be_empty
  end
end
