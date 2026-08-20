require "../spec_helper"

# `Gori::Export::Curl` — the curl serializer that used to live inside `Tui::CopyMenu` and now
# backs BOTH the TUI's "Copy as → cURL" row and `gori run show <id> --format curl`. The point
# of the move is that there is one of it; these specs pin what it emits, and
# spec/tui/copy_menu_spec.cr pins that the menu still offers exactly that text.

private def curl_of(wire : String, target : String) : String
  Gori::Export::Curl.text(wire, target).not_nil!
end

describe Gori::Export::Curl do
  describe ".text" do
    it "drops Host and Content-Length — curl derives both from the URL and the body" do
      cmd = curl_of("POST /api/login HTTP/1.1\r\nHost: example.com\r\n" \
                    "Content-Length: 14\r\nX-Key: k\r\n\r\n{\"user\":\"neo\"}",
        "https://example.com")
      cmd.should contain("curl 'https://example.com/api/login'")
      cmd.should contain("-H 'X-Key: k'")
      cmd.should_not contain("-H 'Host:")
      cmd.should_not contain("Content-Length")
    end

    it "keeps the query string on the URL and does not re-emit it anywhere else" do
      cmd = curl_of("GET /search?q=a%20b&page=2 HTTP/1.1\r\nHost: h.test\r\n\r\n", "https://h.test")
      cmd.should contain("curl 'https://h.test/search?q=a%20b&page=2'")
    end

    it "omits -X for a plain bodyless GET (curl's default) and emits it for anything else" do
      curl_of("GET /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h").should_not contain("-X")
      curl_of("DELETE /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h").should contain("-X 'DELETE'")
    end

    # The METHOD is a captured token, not gori's text: `parse_request_head` refuses only
    # SP/CTL/DEL on the request line and `Import::Builder.reject_inject!` only CR/LF/NUL, so
    # every shell metacharacter reaches this serializer from a client on the wire or from an
    # imported HAR. Unquoted, `-X GET;curl|sh` ran a second command in the operator's shell on
    # paste. Pinned per metacharacter rather than as one example: this is the ONE argument that
    # was ever spliced raw, and a future "shell-safe method names are fine, skip the quotes"
    # shortcut has to fail on each of them, not just on the one that got written down.
    it "quotes a captured method, so a shell metacharacter in it cannot end the command" do
      {";curl|sh", "`id`", "$(id)", "&&id", ">out"}.each do |tail|
        cmd = curl_of("GET#{tail} /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h")
        cmd.should contain("-X 'GET#{tail}'")
        # …and nothing outside the quotes for a shell to read as syntax.
        cmd.lines.last.should eq("  -X 'GET#{tail}'")
      end
    end

    # The one byte quoting cannot rescue, on the same command `data_argument` already refuses it
    # for. bash truncates an argv element at a NUL, so `-X 'GET<NUL>x'` would have LOOKED right
    # on screen and sent `GET`. Nothing validates the method (see `command`); the proxy path can
    # carry a NUL through, the import path refuses it.
    it "refuses -X for a method holding a NUL instead of emitting one bash would truncate" do
      cmd = curl_of("GET\u0000x /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h")
      # Not `should_not contain("-X ")` — the note itself says "-X omitted". What must be
      # absent is the ARGUMENT: no line whose own first token is -X.
      cmd.lines.any? { |l| l.lstrip.starts_with?("-X ") }.should be_false
      cmd.should contain("# -X omitted")
      # LAST line: a `#` comment swallows the ` \` that continues the command, so the note has
      # to sit where there is nothing left for it to truncate.
      cmd.lines.last.should start_with("  # -X omitted")
    end

    # A `'` cannot be carried inside '…' — `shell_quote` closes, escapes, reopens. The method
    # goes through the same rewrite as every other argument, so the token stays one word.
    it "escapes a single quote in a captured method instead of breaking out of the quoting" do
      curl_of("GE'T /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h")
        .should contain(%q(-X 'GE'\''T'))
    end

    it "keeps -X GET when a GET carries a body, which curl would otherwise promote to POST" do
      cmd = curl_of("GET /a HTTP/1.1\r\nHost: h\r\n\r\nq=1", "http://h")
      cmd.should contain("-X 'GET'")
      cmd.should contain("--data-raw 'q=1'")
    end

    it "sends a JSON body verbatim through --data-raw, quotes and all" do
      cmd = curl_of("POST /api HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n\r\n" \
                    "{\"user\":\"neo\",\"note\":\"it's fine\"}", "https://h")
      cmd.should contain("-H 'Content-Type: application/json'")
      # POSIX single-quote: the body's own ' becomes '\'' and the rest rides through as typed.
      cmd.should contain(%q(--data-raw '{"user":"neo","note":"it'\''s fine"}'))
    end

    it "resolves an absolute-form request line (a plain-HTTP forward proxy capture) as-is" do
      curl_of("GET http://plain.test/x HTTP/1.1\r\nHost: plain.test\r\n\r\n", "http://plain.test")
        .should contain("curl 'http://plain.test/x'")
    end

    it "returns nil when there is no URL to build — nothing runnable to hand over" do
      Gori::Export::Curl.text("", "").should be_nil
    end
  end

  # An h2 capture is stored as the SYNTHESIZED h1 head `Proxy::H2::HeadCodec.synth_request`
  # writes: an `HTTP/2` request line, a `Host:` standing in for `:authority`, and — capture-side
  # only — gori's own marker lines about the exchange. Both halves matter to a command that
  # claims to reproduce the request.
  describe "an HTTP/2 capture" do
    it "asserts h2 over TLS with --http2 (ALPN does the rest)" do
      cmd = curl_of("GET /a HTTP/2\r\nHost: h2.test\r\naccept: */*\r\n\r\n", "https://h2.test")
      cmd.should contain("--http2")
      cmd.should_not contain("--http2-prior-knowledge")
    end

    it "asserts cleartext h2c with --http2-prior-knowledge, which has no ALPN to negotiate" do
      curl_of("GET /a HTTP/2\r\nHost: h2c.test\r\n\r\n", "http://h2c.test:8080")
        .should contain("--http2-prior-knowledge")
    end

    it "leaves HTTP/1.1 alone — it is curl's default" do
      curl_of("GET /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h").should_not contain("--http")
    end

    # These three lines are gori speaking ABOUT the exchange (which fields arrived in a
    # trailing HEADERS block, that the ORIGIN invented this request in a PUSH_PROMISE, an
    # RFC 8441 `:protocol`). No client put them on a wire, so a reproduction must not send them.
    it "does not send gori's own marker lines back to the origin" do
      cmd = curl_of("GET /a HTTP/2\r\nHost: h2.test\r\n" \
                    "#{Gori::Proxy::H2::HeadCodec::TRAILER_MARKER}: grpc-status\r\n" \
                    "#{Gori::Proxy::H2::HeadCodec::PUSHED_MARKER}: server push promised on stream 3\r\n" \
                    "#{Gori::Proxy::H2::HeadCodec::PROTOCOL_MARKER}: websocket\r\n" \
                    "x-real: kept\r\n\r\n", "https://h2.test")
      cmd.should_not contain("X-Gori-")
      cmd.should contain("-H 'x-real: kept'")
    end
  end

  describe "a body no shell argument can carry" do
    it "refuses a NUL-bearing body in a comment rather than sending a SHORTER one" do
      cmd = curl_of("POST /a HTTP/1.1\r\nHost: h\r\n\r\nab\u{0}cd", "http://h")
      cmd.should_not contain("--data-raw")
      cmd.should contain("# body omitted")
      cmd.should contain("--data-binary @FILE")
    end
  end
end
