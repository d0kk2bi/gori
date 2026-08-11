require "../spec_helper"

private alias WS = Gori::Proxy::WS

private class TruncSink < Gori::Proxy::FlowSink
  getter rows = [] of {String, Int32, Bytes}

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @rows << {direction, opcode, payload.dup}
  end
end

private def data_frame(fin : Bool, payload : Bytes) : WS::Frame
  WS::Frame.new(fin, WS::OP_TEXT, payload, Bytes.empty)
end

# The raw forward is byte-exact either way (P7); only the captured PROJECTION is capped at
# MAX_MESSAGE. The oversized-FRAME path already writes a `NOTICE_PREFIX` marker row saying so
# ("too large to capture"), but a message assembled past the cap by FRAGMENTATION used to be
# written with `fin: true` and a plausible payload and nothing else — so a truncated
# transcript was indistinguishable from a complete one. `ws_messages` has no truncation
# column (unlike `CapturedResponse#body_truncated`), hence a row of its own.
describe "WS capture truncation" do
  it "marks a fragmented message that overruns the capture cap" do
    sink = TruncSink.new
    shape = WS::MessageShape.new
    buf = IO::Memory.new

    # First fragment fills the buffer to just under the cap; the second crosses it.
    head = Bytes.new(WS::Relay::MAX_MESSAGE - 4, 'A'.ord.to_u8)
    shape.note(false, 0_u8, false, nil)
    buf = WS::Relay.capture_frame(data_frame(false, head), buf, "out", 1_i64, sink,
      WS::OP_TEXT, shape)
    sink.rows.should be_empty # no FIN yet, and nothing dropped yet

    tail = Bytes.new(64, 'B'.ord.to_u8)
    shape.note(true, 0_u8, false, nil)
    WS::Relay.capture_frame(data_frame(true, tail), buf, "out", 1_i64, sink,
      WS::OP_TEXT, shape)

    sink.rows.size.should eq(2)

    notice, payload = sink.rows[0], sink.rows[1]
    WS.notice?(notice[2]).should be_true
    String.new(notice[2]).should contain("truncated")
    # The payload row keeps the captured PREFIX — that is the evidence worth having — and
    # stops exactly at the cap.
    WS.notice?(payload[2]).should be_false
    payload[2].size.should eq(WS::Relay::MAX_MESSAGE)
  end

  it "does not mark a message that fits, and emits it once on FIN" do
    sink = TruncSink.new
    shape = WS::MessageShape.new
    buf = IO::Memory.new

    shape.note(false, 0_u8, false, nil)
    buf = WS::Relay.capture_frame(data_frame(false, "AAA".to_slice), buf, "in", 1_i64, sink,
      WS::OP_TEXT, shape)
    shape.note(true, 0_u8, false, nil)
    WS::Relay.capture_frame(data_frame(true, "BBB".to_slice), buf, "in", 1_i64, sink,
      WS::OP_TEXT, shape)

    sink.rows.size.should eq(1)
    String.new(sink.rows[0][2]).should eq("AAABBB")
  end

  # One notice per MESSAGE, not one per fragment: after the crossing frame every later
  # fragment also drops bytes, and a notice for each would bury the transcript.
  it "marks the overrun exactly once across later fragments" do
    sink = TruncSink.new
    shape = WS::MessageShape.new
    buf = IO::Memory.new

    head = Bytes.new(WS::Relay::MAX_MESSAGE - 4, 'A'.ord.to_u8)
    shape.note(false, 0_u8, false, nil)
    buf = WS::Relay.capture_frame(data_frame(false, head), buf, "out", 1_i64, sink,
      WS::OP_TEXT, shape)

    3.times do
      shape.note(false, 0_u8, false, nil)
      buf = WS::Relay.capture_frame(data_frame(false, Bytes.new(32, 'B'.ord.to_u8)), buf,
        "out", 1_i64, sink, WS::OP_TEXT, shape)
    end
    shape.note(true, 0_u8, false, nil)
    WS::Relay.capture_frame(data_frame(true, Bytes.new(32, 'C'.ord.to_u8)), buf, "out",
      1_i64, sink, WS::OP_TEXT, shape)

    notices = sink.rows.count { |(_, _, p)| WS.notice?(p) }
    notices.should eq(1)
  end
end
