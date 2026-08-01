require "../spec_helper"

# The CAPTURED-FLOW Content-Length policy.
#
# `send_request{flow_id}` documents a flow replay as byte-exact and was not: it inherited
# `auto_content_length: true` and rewrote the stored CL line on every send. So a captured
# `Content-Length: 99` over a 2-byte body — a CL-desync probe someone captured *because* it
# is wrong — went out as `Content-Length: 2`, with `isError:false` and no notice. The
# operator read a verdict about a request gori never sent. `gori run repeater <flow-id>`
# had the same behaviour.
#
# The one case that must still recompute is why the resync exists on this path at all: a
# `$KEY` in the body, whose expansion changes the body length AFTER the CL was framed over
# the pre-expansion bytes. Distinguishing the two is what these examples pin.
describe "Gori::Repeater::FlowRequest.resync_content_length_if_body_changed" do
  it "leaves a deliberately-wrong Content-Length alone when the body did not change" do
    wire = "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 99\r\n\r\nAB".to_slice
    res = Gori::Repeater::FlowRequest.resync_content_length_if_body_changed(wire, wire)
    String.new(res).should eq("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 99\r\n\r\nAB")
  end

  it "recomputes only when expansion changed the BODY's length" do
    before = "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\np=$PW".to_slice
    after = "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\np=hunter2".to_slice
    res = String.new(Gori::Repeater::FlowRequest.resync_content_length_if_body_changed(before, after))
    res.should contain("Content-Length: 9\r\n")
    res.should end_with("p=hunter2")
  end

  it "does NOT recompute when expansion only touched the HEAD" do
    # Otherwise a `$KEY` in a header would become a licence to overwrite a pinned CL that
    # has nothing to do with it.
    before = "POST /x HTTP/1.1\r\nX-A: $PW\r\nContent-Length: 99\r\n\r\nAB".to_slice
    after = "POST /x HTTP/1.1\r\nX-A: hunter2\r\nContent-Length: 99\r\n\r\nAB".to_slice
    String.new(Gori::Repeater::FlowRequest.resync_content_length_if_body_changed(before, after))
      .should contain("Content-Length: 99\r\n")
  end

  it "is a no-op on a message with no CRLFCRLF terminator (nothing to split on)" do
    raw = "GET /only-a-head".to_slice
    String.new(Gori::Repeater::FlowRequest.resync_content_length_if_body_changed(raw, raw))
      .should eq("GET /only-a-head")
  end
end

# `Env.head_body_boundary` is the shared head/body split. MCP's History recording used to
# carry its own CRLFCRLF-only scan that RAISED when it found none — which made
# `record_history` (on by default) refuse to send a bare-LF-terminated request at all, the
# exact payload `verbatim:true` advertises. Making the shared one public is the fix, so its
# contract is pinned here.
describe "Gori::Env.head_body_boundary" do
  it "accepts a bare-LF header terminator" do
    Gori::Env.head_body_boundary("GET / HTTP/1.1\nHost: h\n\nbody".to_slice).should eq(24)
  end

  it "accepts a CRLF header terminator" do
    Gori::Env.head_body_boundary("GET / HTTP/1.1\r\nHost: h\r\n\r\nbody".to_slice).should eq(27)
  end

  it "takes whichever spelling comes FIRST, not a fixed preference" do
    # A body that itself contains a CRLFCRLF must not move the boundary past the real one.
    bytes = "GET / HTTP/1.1\nHost: h\n\nA\r\n\r\nB".to_slice
    Gori::Env.head_body_boundary(bytes).should eq(24)
  end

  it "returns the full size when there is no terminator at all" do
    bytes = "GET /no-terminator HTTP/1.1".to_slice
    Gori::Env.head_body_boundary(bytes).should eq(bytes.size)
  end
end
