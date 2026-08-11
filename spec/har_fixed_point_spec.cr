require "./spec_helper"

private alias ImpHar = Gori::Import::Har

# Build a one-entry HAR and return the heads gori reconstructs from it. Driven through the
# real `parse` seam rather than the private normalizer, so what is pinned is what an operator
# importing a HAR actually gets.
private def import_heads(req_version : String, resp_version : String,
                         status_text : JSON::Any::Type = "OK") : {String, String}
  entry = {
    "startedDateTime" => "2026-01-01T00:00:00.000Z",
    "time"            => 1,
    "request"         => {
      "method" => "GET", "url" => "http://acme.test/x", "httpVersion" => req_version,
      "headers" => [] of Hash(String, String), "queryString" => [] of Hash(String, String),
      "cookies" => [] of Hash(String, String), "headersSize" => -1, "bodySize" => 0,
    },
    "response" => {
      "status" => 200, "statusText" => status_text, "httpVersion" => resp_version,
      "headers" => [] of Hash(String, String), "cookies" => [] of Hash(String, String),
      "content" => {"size" => 0, "mimeType" => "text/plain"},
      "redirectURL" => "", "headersSize" => -1, "bodySize" => 0,
    },
    "cache"   => {} of String => String,
    "timings" => {"send" => 0, "wait" => 1, "receive" => 0},
  }
  har = {"log" => {"version" => "1.2", "entries" => [entry]}}.to_json
  pair = parse_har(har).flows.first
  {String.new(pair.request.head), String.new(pair.response.not_nil!.head)}
end

private def parse_har(json : String) : Gori::Import::ParseResult
  path = File.tempname("gori-har", ".har")
  File.write(path, json)
  begin
    ImpHar.parse_file(path)
  ensure
    File.delete?(path)
  end
end

# `Export::Har` states the contract these pin: for a COMPLETE flow, "version, ordered headers
# with their framing, body bytes, status, reason, timing" survives, and export→import→export
# is a fixed point. Two of those were being rewritten on the way through.
describe "HAR round-trip fixed point" do
  # The export writes the STORED version verbatim and names the importer's normalizer as what
  # maps it back onto itself. Everything outside {1.0, 1.1, 2} used to collapse to HTTP/1.1,
  # silently rewriting an operator's version-line probe — `flow_mapper` keeps the request
  # line's token verbatim, and `Repeater::Plan` deliberately sends HTTP/9.9 unaltered.
  it "keeps an unusual but well-formed version instead of folding it to 1.1" do
    req, _ = import_heads("HTTP/0.9", "HTTP/1.1")
    req.should start_with("GET /x HTTP/0.9\r\n")

    req, _ = import_heads("HTTP/9.9", "HTTP/1.1")
    req.should start_with("GET /x HTTP/9.9\r\n")
  end

  # Chrome DevTools writes "http/2.0". Keeping it verbatim split the codebase's two h2 tests
  # against each other — `starts_with?("HTTP/2")` in the probe layer vs `== "HTTP/2"` in the
  # Repeater — so an imported h2 flow replayed over HTTP/1.1 while being scanned as h2.
  it "folds every h2 spelling to the canonical HTTP/2" do
    {"h2", "http/2", "HTTP/2", "http/2.0", "HTTP/2.0"}.each do |v|
      req, _ = import_heads(v, "HTTP/1.1")
      req.should start_with("GET /x HTTP/2\r\n")
    end
  end

  it "still folds the h2 spellings and defaults a token that is not a version" do
    req, _ = import_heads("h2", "HTTP/1.1")
    req.should start_with("GET /x HTTP/2\r\n")

    req, _ = import_heads("nonsense", "HTTP/1.1")
    req.should start_with("GET /x HTTP/1.1\r\n")
  end

  it "normalizes case without changing the version itself" do
    req, _ = import_heads("http/1.0", "HTTP/1.1")
    req.should start_with("GET /x HTTP/1.0\r\n")
  end

  # `parse_response_head` yields reason == "" for a reason-less status line
  # (`HTTP/1.1 200\r\n`) — a real server fingerprint and a deliberate probe target. Export
  # writes `"statusText": ""`; importing that used to invent "OK", putting three bytes on the
  # head the origin never sent. ABSENT still earns a phrase; PRESENT-BUT-EMPTY does not.
  it "preserves an empty statusText rather than re-inventing a phrase" do
    _, resp = import_heads("HTTP/1.1", "HTTP/1.1", status_text: "")
    resp.should start_with("HTTP/1.1 200\r\n")
  end

  # `JSON::Any#[]?` returns JSON::Any(nil) for an EXPLICIT null, which is TRUTHY — so a
  # foreign HAR writing `"statusText": null` took the present branch and fabricated the
  # reason-less status line that is supposed to mean the origin really sent one.
  it "treats an explicit null statusText as absent, not as an empty phrase" do
    _, resp = import_heads("HTTP/1.1", "HTTP/1.1", status_text: nil)
    resp.should start_with("HTTP/1.1 200 OK\r\n")
  end

  it "still invents a phrase when statusText is absent entirely" do
    entry = {
      "startedDateTime" => "2026-01-01T00:00:00.000Z",
      "time"            => 1,
      "request"         => {
        "method" => "GET", "url" => "http://acme.test/x", "httpVersion" => "HTTP/1.1",
        "headers" => [] of Hash(String, String), "queryString" => [] of Hash(String, String),
        "cookies" => [] of Hash(String, String), "headersSize" => -1, "bodySize" => 0,
      },
      "response" => {
        "status" => 200, "httpVersion" => "HTTP/1.1",
        "headers" => [] of Hash(String, String), "cookies" => [] of Hash(String, String),
        "content" => {"size" => 0, "mimeType" => "text/plain"},
        "redirectURL" => "", "headersSize" => -1, "bodySize" => 0,
      },
      "cache"   => {} of String => String,
      "timings" => {"send" => 0, "wait" => 1, "receive" => 0},
    }
    har = {"log" => {"version" => "1.2", "entries" => [entry]}}.to_json
    pair = parse_har(har).flows.first
    String.new(pair.response.not_nil!.head).should start_with("HTTP/1.1 200 OK\r\n")
  end
end
