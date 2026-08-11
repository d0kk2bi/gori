# Discover's per-RESPONSE fingerprint cost — the one piece of CPU every send pays.
#
# `discover_extract_bench` measures the link pass, but that runs only on CRAWL bodies and is
# bounded by `max_pages`. `Fingerprint.simhash` is different: `Engine#distill` calls it on
# EVERY response, and a brute-force pass is ~315 sends per directory against a soft-404 page
# that is usually a full framework error page, not a stub. So this is the cost that scales
# with the request count, and on the single-threaded scheduler (no -Dpreview_mt) every
# microsecond of it is taken from the same thread the orchestrator dispatches on.
#
# `hamming` is measured separately because its caller multiplies it: `ClusterMap#observe`
# linear-scans up to MAX_CLUSTERS = 4096 representatives per crawl page, and
# `Calibrate.hit?`'s `fp_novel` runs it over the baseline set for every probe.
#
# The legacy implementations below are the ones this bench exists to have replaced; they are
# kept so the comparison is measured rather than remembered, and so EQUIVALENCE is pinned —
# a faster fingerprint that returns a different UInt64 would silently re-cluster every
# baseline in the engine.
#
# Build: crystal build bench/discover_fingerprint_bench.cr -o bin/discover_fingerprint_bench --release
# Run:   bin/discover_fingerprint_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/discover/fingerprint"

include Gori::Discover

# ── the implementations this replaced ───────────────────────────────────────────────────────
#
# One ±1 vote per BIT per token: 64 iterations of shift/mask/compare/branch into a
# StaticArray, on a hash whose bits are ~50/50, which is a branch predictor's worst case.
module Legacy
  FNV_OFFSET = 0xcbf29ce484222325_u64
  FNV_PRIME  = 0x00000100000001b3_u64

  def self.simhash(body : Bytes) : UInt64
    votes = StaticArray(Int32, 64).new(0)
    tokens = 0
    i = 0
    n = body.size
    while i < n && tokens < Fingerprint::MAX_TOKENS
      while i < n && !alnum?(body.unsafe_fetch(i))
        i += 1
      end
      start = i
      while i < n && alnum?(body.unsafe_fetch(i))
        i += 1
      end
      len = i - start
      next if len == 0
      next if dynamic?(body, start, len)
      tokens += 1
      h = fnv1a(body, start, len)
      bit = 0
      while bit < 64
        if (h >> bit) & 1_u64 == 1_u64
          votes.to_unsafe[bit] += 1
        else
          votes.to_unsafe[bit] -= 1
        end
        bit += 1
      end
    end
    out = 0_u64
    bit = 0
    while bit < 64
      out |= (1_u64 << bit) if votes.to_unsafe[bit] > 0
      bit += 1
    end
    out
  end

  # Kernighan's clear-the-lowest-set-bit loop: one iteration per differing bit.
  def self.hamming(a : UInt64, b : UInt64) : Int32
    x = a ^ b
    c = 0
    while x != 0
      x &= x - 1
      c += 1
    end
    c
  end

  def self.alnum?(b : UInt8) : Bool
    (b >= 0x30_u8 && b <= 0x39_u8) ||
      (b >= 0x41_u8 && b <= 0x5a_u8) ||
      (b >= 0x61_u8 && b <= 0x7a_u8)
  end

  def self.dynamic?(body : Bytes, start : Int32, len : Int32) : Bool
    all_digits = true
    all_hex = true
    k = 0
    while k < len
      b = body.unsafe_fetch(start + k)
      digit = b >= 0x30_u8 && b <= 0x39_u8
      hex = digit || (b >= 0x61_u8 && b <= 0x66_u8) || (b >= 0x41_u8 && b <= 0x46_u8)
      all_digits = false unless digit
      all_hex = false unless hex
      break unless all_digits || all_hex
      k += 1
    end
    all_digits || (all_hex && len >= 12)
  end

  def self.fnv1a(body : Bytes, start : Int32, len : Int32) : UInt64
    h = FNV_OFFSET
    k = 0
    while k < len
      b = body.unsafe_fetch(start + k)
      b |= 0x20_u8 if b >= 0x41_u8 && b <= 0x5a_u8
      h = (h ^ b.to_u64) &* FNV_PRIME
      k += 1
    end
    h
  end
end

# ── the corpus ──────────────────────────────────────────────────────────────────────────────
#
# Built at RUNTIME and held in an Array the loops index, so LLVM cannot constant-fold the
# calls away — a folded benchmark reports a win that does not exist.

# The response shape a brute-force run sees ~315 times per directory: a framework's 404 page,
# which on anything modern is the full site chrome around a short message, not a stub.
def soft_404 : Bytes
  nav = (1..25).map { |i| %(<li><a href="/section/#{i}">Section #{i}</a></li>) }.join
  ("<!doctype html><html><head><title>404 - Page not found</title>" \
   "<link rel=stylesheet href=/assets/app.css></head><body><header><nav><ul>" +
     nav + "</ul></nav></header><main><h1>Page not found</h1>" \
           "<p>Sorry, the page you requested does not exist. Try the search box above.</p>" \
           "</main><footer>Copyright 2026 Acme Corporation. All rights reserved.</footer></body></html>").to_slice
end

def catalog_page : Bytes
  nav = (1..40).map { |i| %(<a href="/catalog/section-#{i}">S#{i}</a>) }.join
  rows = (1..120).map { |i| %(<a href="/product/#{i}?ref=grid"><img src="/img/p#{i}.jpg">Product #{i}</a>) }.join
  ("<html><head></head><body>" + nav + rows + nav + "</body></html>").to_slice
end

def big_listing : Bytes
  String.build do |io|
    2000.times { |i| io << %(<div class="row-#{i}"><span>item name #{i}</span><a href="/x/#{i}">go</a></div>) }
  end.to_slice
end

def json_doc : Bytes
  String.build do |io|
    io << %({"items":[)
    400.times do |i|
      io << "," if i > 0
      io << %({"id":#{i},"name":"resource name #{i}","href":"/api/v2/resource/#{i}","kind":"widget"})
    end
    io << "]}"
  end.to_slice
end

CORPUS = [
  {"soft-404 page", soft_404},
  {"catalog page ", catalog_page},
  {"json document", json_doc},
  {"big listing  ", big_listing},
]

# ── equivalence, pinned over the corpus AND over adversarial bytes ───────────────────────────
#
# The algebra says the two agree (`votes = 2*ones - tokens`, so `votes > 0` iff `2*ones >
# tokens`), but the algebra is not the pin — a corpus is. Random bytes cover the token
# shapes the pages do not: empty runs, all-digit and long-hex tokens the `dynamic?` filter
# drops, and bodies with no alnum byte at all.
CORPUS.each do |name, body|
  got = Fingerprint.simhash(body)
  want = Legacy.simhash(body)
  raise "simhash disagrees on #{name}: #{got} != #{want}" unless got == want
end

rng = Random.new(20260811)
2000.times do |i|
  size = i < 64 ? i : rng.rand(1..8192)
  body = Bytes.new(size) { rng.rand(256).to_u8 }
  raise "simhash disagrees on random body ##{i} (#{size}B)" unless Fingerprint.simhash(body) == Legacy.simhash(body)
end
# Bodies made ONLY of the token classes the filter reacts to — plus the one that crosses
# MAX_TOKENS. The corpus above tops out around 20k tokens (`"x" * 199_999` is ONE token, and
# the all-digit / long-hex strings yield none), so nothing else reaches the truncation, and it
# is the one input where the `tokens` denominator meets an early exit.
["", "0123456789", "deadbeefcafebabe", "a", ("z" * 400), ("1234 " * 500), ("////" * 500),
 ("DEADBEEFCAFE" * 100), ("x" * 199_999 + " y"), ("ab " * (Fingerprint::MAX_TOKENS + 1)),
 ("ab cd 42 " * (Fingerprint::MAX_TOKENS // 2))].each do |s|
  b = s.to_slice
  raise "simhash disagrees on #{s.bytesize}B edge body" unless Fingerprint.simhash(b) == Legacy.simhash(b)
end
puts "simhash == legacy on #{CORPUS.size} corpus bodies + 2000 random + 11 edge bodies (incl. past MAX_TOKENS)"

HAMMING_PAIRS = Array.new(4096) { |i| {Random.new(i).rand(UInt64), Random.new(i + 99_991).rand(UInt64)} }
HAMMING_PAIRS.each do |a, b|
  raise "hamming disagrees on #{a}/#{b}" unless Fingerprint.hamming(a, b) == Legacy.hamming(a, b)
end
puts "hamming == legacy on #{HAMMING_PAIRS.size} random pairs"
puts ""

CORPUS.each { |name, body| puts "  #{name}: #{body.size}B" }
puts ""

# ── simhash ─────────────────────────────────────────────────────────────────────────────────
CORPUS.each do |name, body|
  Benchmark.ips do |x|
    x.report("legacy simhash #{name}") { Legacy.simhash(body) }
    x.report("       simhash #{name}") { Fingerprint.simhash(body) }
  end
end

# ── hamming, and the scan that multiplies it ────────────────────────────────────────────────
#
# The pairs come out of a runtime Array and every result is accumulated into a value the
# report returns, so neither the call nor the loop can be eliminated.
puts ""
Benchmark.ips do |x|
  x.report("legacy hamming x4096") do
    c = 0
    HAMMING_PAIRS.each { |a, b| c += Legacy.hamming(a, b) }
    c
  end
  x.report("       hamming x4096") do
    c = 0
    HAMMING_PAIRS.each { |a, b| c += Fingerprint.hamming(a, b) }
    c
  end
end

# `ClusterMap#observe` at its bound: MAX_CLUSTERS representatives, none of them within
# `distance`, so every observe walks the whole list — what a page of distinct content costs
# once the map has filled.
FULL_MAP = ClusterMap.new
ClusterMap::MAX_CLUSTERS.times { |i| FULL_MAP.observe(Random.new(i).rand(UInt64) | (1_u64 << (i % 64)), 0) }
MISSES = Array.new(256) { |i| Random.new(i + 7_777_777).rand(UInt64) }

puts ""
puts "ClusterMap: #{ClusterMap::MAX_CLUSTERS} representatives, distance 0 (every observe walks the full list)"
Benchmark.ips do |x|
  x.report("observe (full scan) ") do
    c = 0
    MISSES.each { |fp| c += FULL_MAP.observe(fp, 0) }
    c
  end
end
