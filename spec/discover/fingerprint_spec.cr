require "../spec_helper"

private alias FP = Gori::Discover::Fingerprint

describe Gori::Discover::Fingerprint do
  it "gives near-identical hashes to content differing only in ids/dates" do
    a = FP.simhash("Welcome user 12345 on 2021-01-01 to the account dashboard overview panel".to_slice)
    b = FP.simhash("Welcome user 98765 on 2024-09-09 to the account dashboard overview panel".to_slice)
    FP.hamming(a, b).should be <= 2
  end

  it "gives distant hashes to genuinely different content" do
    a = FP.simhash("the quick brown fox jumps over the lazy sleeping dog again".to_slice)
    b = FP.simhash("completely unrelated administrative control panel interface settings".to_slice)
    FP.hamming(a, b).should be > 5
  end

  # The two above are DISTANCE assertions, and a miscount big enough to matter can still leave
  # near content near and far content far. These pin the majority rule itself, at the token
  # counts where the bit-sliced accumulator drains (every 255 tokens) — the one place the
  # implementation can lose a count without changing the shape of the answer.
  #
  # The oracle needs no second implementation. With exactly TWO distinct tokens, bit j of the
  # result is: set when both hashes set it, clear when neither does, and the MORE FREQUENT
  # token's bit where they disagree. So for n_a > n_b the whole hash collapses to the hash of
  # `a` alone — a majority of one token decides every contested bit, which is precisely what a
  # dropped carry would flip.
  describe "majority across the accumulator drain" do
    # 255 is the drain point, so these straddle it, land on it, and cross it twice.
    {
      {128, 127}, # 255 tokens — drains exactly once, with nothing left over
      {129, 128}, # 257 — one drain plus a remainder
      {200, 199}, # 399
      {300, 299}, # 599 — two drains plus a remainder
      {1, 0},     # the degenerate single-token case
    }.each do |(more, less)|
      it "resolves a #{more}:#{less} split to the majority token" do
        body = (("alpha " * more) + ("bravo " * less)).to_slice
        FP.simhash(body).should eq(FP.simhash("alpha".to_slice))

        # …and the same split the other way round resolves the other way, so the test cannot
        # pass by the two tokens happening to share a hash.
        flipped = (("alpha " * less) + ("bravo " * more)).to_slice
        FP.simhash(flipped).should eq(FP.simhash("bravo".to_slice))
      end
    end

    it "is unchanged by interleaving, so a drain cannot depend on token order" do
      grouped = (("alpha " * 300) + ("bravo " * 299)).to_slice
      interleaved = String.build do |io|
        299.times { io << "alpha bravo " }
        io << "alpha "
      end.to_slice
      FP.simhash(interleaved).should eq(FP.simhash(grouped))
    end

    it "gives an exact tie no bits, on either side of the drain" do
      # Neither token is a majority, so every contested bit stays clear and only the bits BOTH
      # hashes set survive — the `>` in `2 * ones > tokens`, which an off-by-one would turn
      # into `>=` and hand the tie to whichever token was counted last.
      {127, 255}.each do |n|
        tie = (("alpha " * n) + ("bravo " * n)).to_slice
        both = FP.simhash("alpha".to_slice) & FP.simhash("bravo".to_slice)
        FP.simhash(tie).should eq(both)
      end
    end

    # `tokens` changed ROLE with the bit-sliced accumulator. It used to bound the loop and
    # nothing else, so miscounting it was invisible; it is now the DENOMINATOR every output bit
    # is decided against (`2 * ones > tokens`). A token that is counted but never folded in —
    # the shape a `tokens += 1` that drifted above the `dynamic?` guard would produce — inflates
    # the denominator without contributing any ones, and silently clears every contested bit.
    #
    # Nothing else here catches that: the all-dynamic body below answers 0 either way, and the
    # majority cases hold no dynamic tokens at all.
    it "counts only the tokens it folds in, so a skipped one cannot move the majority" do
      # 200 `alpha` against 199 `bravo`, with an all-digit token after each — `dynamic?` drops
      # those, so the denominator is 399 and not 798.
      body = (("alpha 12345 " * 200) + ("bravo 67890 " * 199)).to_slice
      FP.simhash(body).should eq(FP.simhash("alpha".to_slice))
    end

    it "counts a body with no scannable token as empty" do
      FP.simhash(Bytes.new(0)).should eq(0_u64)
      FP.simhash("   ---   ".to_slice).should eq(0_u64)
      # Every token here is `dynamic?` (all-digit / long-hex) and therefore skipped, so the
      # body scans to zero tokens even though it is full of alnum runs.
      FP.simhash("12345 6789 deadbeefcafebabe 0123456789ab".to_slice).should eq(0_u64)
    end
  end
end

describe "Gori::Discover::Fingerprint.hamming" do
  it "counts differing bits" do
    FP.hamming(0_u64, 0_u64).should eq(0)
    FP.hamming(0_u64, UInt64::MAX).should eq(64)
    FP.hamming(UInt64::MAX, UInt64::MAX).should eq(0)
    FP.hamming(0b1011_u64, 0b0001_u64).should eq(2)
    FP.hamming(1_u64 << 63, 0_u64).should eq(1)
    # Symmetric, and never negative — it feeds `<=` comparisons against `simhash_distance`.
    FP.hamming(0x0123456789abcdef_u64, 0xfedcba9876543210_u64).should eq(64)
    FP.hamming(0xfedcba9876543210_u64, 0x0123456789abcdef_u64).should eq(64)
  end
end

describe Gori::Discover::ClusterMap do
  it "counts distinct entries mapping to one content cluster" do
    cm = Gori::Discover::ClusterMap.new
    h = FP.simhash("product listing page row item price add to cart".to_slice)
    cm.observe(h, 3).should eq(1)
    cm.observe(h, 3).should eq(2)
    cm.observe(h, 3).should eq(3)
    other = FP.simhash("a totally separate unique article body with prose here".to_slice)
    cm.observe(other, 3).should eq(1)
  end
end
