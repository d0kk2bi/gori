require "../../spec_helper"

# `gori run intercept edit --raw-file` is this subcommand's only byte-exact channel (there is
# no `--raw-base64` here, and argv cannot carry a NUL). Its own help promised the bytes are
# forwarded VERBATIM, but the whole message was CRLF-normalized — head AND body — so an
# operator's `alpha\rbeta\ngamma` reached the origin a byte longer with its bare LF promoted,
# under a Content-Length gori then recomputed over the corrupted body.
#
# Every other edit path on this branch is head-only (`Env.expand_wire` locates
# `head_body_boundary` first; the TUI's `intercept_view` does the same). The CLI is the one
# surface that never got the split.
describe "Gori::CLI::Run.normalize_head_crlf" do
  it "CRLF-terminates header lines and leaves the BODY byte-exact" do
    raw = "POST /held HTTP/1.1\nHost: h\nContent-Length: 5\n\nalpha\rbeta\ngamma".to_slice
    String.new(Gori::CLI::Run.normalize_head_crlf(raw))
      .should eq("POST /held HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nalpha\rbeta\ngamma")
  end

  it "is a no-op on a message whose head is already CRLF" do
    raw = "POST /held HTTP/1.1\r\nHost: h\r\nContent-Length: 16\r\n\r\nalpha\rbeta\ngamma".to_slice
    Gori::CLI::Run.normalize_head_crlf(raw).should eq(raw)
  end

  it "leaves a binary body untouched, including CR/LF/NUL bytes" do
    body = Bytes[0x0A, 0x00, 0x0D, 0xFF, 0x0A]
    raw = "POST /b HTTP/1.1\r\n\r\n".to_slice + body
    out = Gori::CLI::Run.normalize_head_crlf(raw)
    out[("POST /b HTTP/1.1\r\n\r\n".bytesize)..].to_a.should eq(body.to_a)
  end

  it "normalizes a head with no body at all" do
    String.new(Gori::CLI::Run.normalize_head_crlf("GET / HTTP/1.1\nHost: h\n\n".to_slice))
      .should eq("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
  end
end

# `HeldRow#target` carries TWO different things depending on `kind`: a request's target, or a
# RESPONSE's status reason. The row builder never branched on it, so a held response rendered
# as `http://127.0.0.1200 OK` — a string that looks like a URL, is not one, drops the port,
# and left several held responses to different paths indistinguishable.
private def held(kind : String, target : String, flow_id : Int64? = nil) : Gori::Store::HeldRow
  Gori::Store::HeldRow.new(
    session_token: "t", item_id: 2_i64, kind: kind, method: "POST", host: "127.0.0.1",
    port: 19501, scheme: "http", target: target, raw: Bytes.empty, held_at_ms: 0_i64,
    flow_id: flow_id)
end

describe "Gori::CLI::Run.intercept_row_where" do
  it "renders a held RESPONSE as an authority plus its status reason, never as a URL" do
    Gori::CLI::Run.intercept_row_where(held("response", "200 OK", 2_i64))
      .should eq("http://127.0.0.1:19501 → 200 OK  (flow #2)")
  end

  it "omits the flow reference when the row does not carry one" do
    Gori::CLI::Run.intercept_row_where(held("response", "404 Not Found"))
      .should eq("http://127.0.0.1:19501 → 404 Not Found")
  end

  it "keeps a request held in ABSOLUTE form exactly as the wire had it" do
    Gori::CLI::Run.intercept_row_where(held("request", "http://127.0.0.1:19501/held"))
      .should eq("http://127.0.0.1:19501/held")
  end

  it "hangs an origin-form request off the authority — INCLUDING the port" do
    Gori::CLI::Run.intercept_row_where(held("request", "/held"))
      .should eq("http://127.0.0.1:19501/held")
  end
end

# R4. The refusal is decided when the message is HELD, and it reached no read surface: the
# operator (or the agent) composed an edit against a message described as ordinarily editable
# and learned otherwise from the ack. Both projections say so up front now.
private def refusing_row(refusal : String? = nil, head_only : Bool = false) : Gori::Store::HeldRow
  Gori::Store::HeldRow.new(
    session_token: "t", item_id: 1_i64, kind: "request", method: "GET", host: "h",
    port: 443, scheme: "https", target: "/a",
    raw: "GET /a HTTP/2\r\nHost: h\r\n\r\n".to_slice, held_at_ms: 0_i64,
    edit_refusal: refusal, head_only: head_only)
end

describe "held-item edit refusal on the read surfaces" do
  it "emits the reason and the head-only hold in the MCP list and detail projections" do
    row = refusing_row("the value of \"x-evil\" carries a CR or LF", head_only: true)
    listed = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.intercept_item_row(j, row, false, 0_i64) })
    listed["edit_refusal"].as_s.should contain("x-evil")
    listed["head_only"].as_bool.should be_true
    detail = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.intercept_item_detail(j, row, false, 0_i64) })
    detail["edit_refusal"].as_s.should contain("x-evil")
  end

  # A head-only hold with NO refusal is still editable — only a BODY has nowhere to go — so
  # the warning has to say that and not "edits are refused".
  it "warns about a head-only hold without claiming the message is uneditable" do
    row = refusing_row(nil, head_only: true)
    row.edit_warning.not_nil!.should contain("HEAD only")
    row.edit_warning.not_nil!.should_not contain("CR or LF")
    JSON.parse(JSON.build { |j| Gori::MCP::Serialize.intercept_item_row(j, row, false, 0_i64) })["head_only"]
      .as_bool.should be_true
  end

  # The complement: an h1 hold covers head+body and forwards byte-exact, so neither field is
  # emitted and a client keying off field presence sees exactly the shape it saw before.
  it "says nothing at all about an ordinary h1 hold" do
    row = refusing_row
    row.edit_warning.should be_nil
    obj = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.intercept_item_row(j, row, false, 0_i64) }).as_h
    obj.has_key?("edit_refusal").should be_false
    obj.has_key?("head_only").should be_false
  end
end
