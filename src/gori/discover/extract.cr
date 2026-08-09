module Gori::Discover
  # Link extraction from a response body — the spider's discovery source. Net-new (the
  # repo's links.cr is unrelated; it resolves DB entity_links). A single bounded pass of
  # regexes over the DECODED body; no JS execution (matches ZAP's default spider — AJAX/SPA
  # links are a documented FN). The caller (engine worker) decides which extractor to run
  # from the response content-type / task source.
  module Extract
    MAX_SCAN = 2 * 1024 * 1024 # cap the scanned body so a hostile 1 GB page can't stall a worker

    # Ceiling on what ONE body may contribute to the frontier. Every entry costs the
    # ORCHESTRATOR fiber — the same fiber that dispatches every job — a `Url.resolve`, a
    # `Url.parse`, a `visit_key` and a `template_key` in `consider_link`, so a body full of
    # distinct path literals (a generated bundle as easily as a hostile one) must not be able
    # to buy unbounded orchestrator time. `Engine::MAX_SEEN` bounds the same bookkeeping
    # globally; this bounds what a single response can spend, before it is ever queued.
    MAX_LINKS = 4096

    # href / src / action attributes (quoted or bare), plus <meta refresh url=…>.
    #
    # The alternation is deliberately UNANCHORED (no `\b`), which is why `data-src`,
    # `data-href` and `formaction` are already covered by `src`/`href`/`action` — only the
    # attributes whose name shares no suffix with those three need naming. `srcset` is
    # deliberately NOT matched: its value is a comma-separated `url 1x, url 2x` descriptor
    # list, not one URL, so capturing it whole would hand `Url.resolve` a string it would
    # percent-encode into a URL nobody serves.
    ATTR = /(?:href|src|action|poster|data-(?:url|uri|endpoint|api))\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i
    META = /<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]*content\s*=\s*["'][^"']*url\s*=\s*([^"'>\s]+)/i
    LOC  = /<loc>\s*([^<\s]+)\s*<\/loc>/i

    # An endpoint literal in NON-markup text: an absolute http(s) URL, or a root-relative path
    # opening a quoted string. Two branches in one pass because the two shapes interleave
    # freely in the bodies this runs over.
    #
    # The path branch requires the quote, and that single character is what keeps the false
    # positives down: a JS regex literal (`/foo/g`), a MIME type (`application/json`), a date
    # (`2026/07/19`) and a division all fail it, while `fetch("/api/v2/cart")`,
    # `{"href":"/account"}` and `` `/api/users/${id}` `` all match. The last one stops at `$`
    # and yields the DIRECTORY `/api/users/`, which is exactly what the brute-forcer wants
    # from an interpolated route.
    #
    # The closing quote is NOT required — an interpolated or concatenated path has none, and
    # the character class already terminates the run. `{1,256}` bounds it: a path longer than
    # that is not a path.
    ENDPOINT = /https?:\/\/[^\s"'`<>\\,;)\]}]{3,}|["'`](\/[A-Za-z0-9_\-.~%\/]{1,256})/i

    def self.from_html(body : Bytes) : Array(String)
      # `acc`, not `out`: `out` is a Crystal keyword in ARGUMENT position, so a local named
      # that cannot be passed to `endpoints` below (it parses as an out-parameter).
      acc = [] of String
      seen = Set(String).new
      text = scan_text(body)
      text.scan(ATTR) do |m|
        break if acc.size >= MAX_LINKS
        v = m[1]? || m[2]? || m[3]?
        acc << v if v && !v.empty? && seen.add?(v)
      end
      text.scan(META) do |m|
        v = m[1]?
        acc << v if v && !v.empty? && seen.add?(v)
      end
      # Inline <script> — where a single-page app keeps the endpoints no attribute names, and
      # where a server-rendered page keeps its bootstrap JSON. Run over the WHOLE body rather
      # than over extracted <script> blocks: the pass is one regex either way, finding the
      # blocks is a second one, and anything it re-finds in an attribute is already `seen`.
      endpoints(text, acc, seen)
      acc
    end

    # Endpoint literals from a body that is neither markup nor a sitemap: a script bundle, a
    # JSON document (every `.well-known/` one is), a `.map`, a plain-text policy file.
    #
    # These used to yield NOTHING. The spider follows `<script src>` like any other link,
    # fetched the bundle, and then dropped every endpoint in it on the floor because the
    # content type was not html-like — the largest false-negative class there is on anything
    # SPA-shaped, since an API route reachable only from JS is by construction unlinked and
    # therefore invisible to both halves of the engine.
    #
    # Content-type-blind on purpose: the two shapes it looks for are spelled identically in
    # JS, JSON, YAML, XML and plain text, so the caller only has to decide whether the bytes
    # are text at all (`Engine#text_like?`).
    def self.from_text(body : Bytes) : Array(String)
      acc = [] of String
      endpoints(scan_text(body), acc, Set(String).new)
      acc
    end

    # Appends every distinct ENDPOINT match to `acc`. `seen` is shared with the caller so an
    # href already captured by ATTR is not re-added when the same string appears in an inline
    # script.
    private def self.endpoints(text : String, acc : Array(String), seen : Set(String)) : Nil
      return if acc.size >= MAX_LINKS
      text.scan(ENDPOINT) do |m|
        break if acc.size >= MAX_LINKS
        # Group 1 is the path branch's capture; on the URL branch it is nil and the whole
        # match IS the URL.
        v = m[1]? || m[0]
        acc << v if !v.empty? && seen.add?(v)
      end
    end

    # robots.txt Disallow/Allow/Sitemap values → candidate paths (a bare "/" is not useful).
    def self.from_robots(body : Bytes) : Array(String)
      out = [] of String
      scan_text(body).each_line do |line|
        l = line.strip
        next if l.empty? || l.starts_with?('#')
        low = l.downcase
        next unless low.starts_with?("disallow:") || low.starts_with?("allow:") || low.starts_with?("sitemap:")
        val = l.partition(':')[2].strip
        # a Disallow may carry a trailing comment or a glob; take the token up to whitespace/*.
        val = val.split(/[\s*]/).first? || ""
        out << val unless val.empty? || val == "/"
      end
      out
    end

    # sitemap.xml <loc> URLs. Handles both a <urlset> (page URLs) and a <sitemapindex>
    # (child-sitemap URLs) — both use <loc>, so index recursion falls out for free.
    def self.from_sitemap(body : Bytes) : Array(String)
      out = [] of String
      scan_text(body).scan(LOC) do |m|
        v = m[1]?
        out << v if v && !v.empty?
      end
      out
    end

    SNIFF_MAX    = 8192 # a sitemap's root element sits at the top; no need to read further
    SITEMAP_ROOT = /<(?:urlset|sitemapindex|loc)\b/i

    # Does this body look like an XML sitemap? Lets the engine pick the sitemap parser from
    # the RESPONSE rather than from how the URL was found — so a sitemap served off the
    # well-known /sitemap.xml path (a robots.txt `Sitemap:` URL, or a <sitemapindex> child)
    # still gets its <loc> URLs extracted instead of being wrongly parsed as HTML/robots.
    def self.sitemap_body?(body : Bytes) : Bool
      slice = body.size > SNIFF_MAX ? body[0, SNIFF_MAX] : body
      text(slice).matches?(SITEMAP_ROOT)
    end

    private def self.scan_text(body : Bytes) : String
      slice = body.size > MAX_SCAN ? body[0, MAX_SCAN] : body
      text(slice)
    end

    # A response body as a String the PCRE2 scans above can be run over. The scrub is
    # required — `String.new` validates nothing, and a Regex on invalid UTF-8 raises — but it
    # is only required for a body that is ACTUALLY invalid, and `String#scrub` charges for the
    # check either way: it walks the whole string through a `Char::Reader` and returns `self`
    # at the end, which measured 130µs on a valid 40 KB page against 9µs for
    # `valid_encoding?`. Every crawled page and every brute-force probe response pays this, so
    # ask the cheap question first and scrub only the bodies that need it (`scrub` re-walks
    # them, which is the right trade at ~1 body in a run).
    private def self.text(slice : Bytes) : String
      s = String.new(slice)
      s.valid_encoding? ? s : s.scrub
    end
  end
end
