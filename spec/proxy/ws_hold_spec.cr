require "../spec_helper"

# WebSocket message HOLD (#500 step 2): `WS::MessageGate` in front of the assembling pump.
#
# The headline proof is the first example: a message can sit in the queue for as long as a
# human needs while PING/PONG keeps flowing past it and the opposite direction keeps running.
# That is what makes a WS hold survivable at all — a blocked pump would stop relaying the
# client's PONG, and a server pinging on the usual 20-30 s timer closes the socket well inside
# a minute, so a two-minute edit would reliably kill the connection being inspected.

private alias WS = Gori::Proxy::WS

# The 101 handshake identity every hold scopes and labels on.
private HOLD_CTX = WS::Context.new(host: "echo.test", port: 80, scheme: "http",
  method: "GET", target: "/ws")

# One direction's pipes plus the two stapled IOs `Relay.run` is handed. `cs_w` writes as the
# client, `ts_r` reads as the origin, `ss_w` writes as the origin, `tc_r` reads as the client.
private record Rig,
  client : IO,
  upstream : IO,
  cs_w : IO,
  ts_r : IO,
  ss_w : IO,
  tc_r : IO do
  def shutdown : Nil
    cs_w.close rescue nil
    ss_w.close rescue nil
  end
end

private def rig : Rig
  cs_r, cs_w = IO.pipe # client → relay
  ts_r, ts_w = IO.pipe # relay → origin
  ss_r, ss_w = IO.pipe # origin → relay
  tc_r, tc_w = IO.pipe # relay → client
  Rig.new(IO::Stapled.new(cs_r, tc_w, sync_close: true),
    IO::Stapled.new(ss_r, ts_w, sync_close: true), cs_w, ts_r, ss_w, tc_r)
end

private class HoldSink < Gori::Proxy::FlowSink
  getter messages = [] of {String, Int32, String}

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @messages << {direction, opcode, String.new(payload)}
  end
end

# An Interceptor with catch ON and `query` committed, over a throwaway store (Scope needs one).
private def with_interceptor(query : String, &)
  path = File.tempname("gori-ws-hold", ".db")
  store = Gori::Store.open(path)
  begin
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    ic.toggle # enable
    ic.set_filter(query)
    yield ic
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Poll a condition rather than sleeping a fixed beat: the hold happens on the pump fiber, and
# a fixed sleep would be either flaky or slow. Raises instead of hanging the suite.
private def wait_until(what : String, timeout = 3.seconds, &block : -> Bool) : Nil
  deadline = Time.instant + timeout
  until block.call
    raise "timed out waiting for #{what}" if Time.instant > deadline
    sleep 1.millisecond
  end
end

private def masked(opcode : UInt8, payload : Bytes, fin : Bool = true) : Bytes
  mask = Bytes[0xAA, 0xBB, 0xCC, 0xDD]
  io = IO::Memory.new
  io.write_byte((fin ? 0x80_u8 : 0_u8) | opcode)
  io.write_byte((0x80 | payload.size).to_u8)
  io.write(mask)
  payload.each_with_index { |b, i| io.write_byte(b ^ mask[i & 3]) }
  io.to_slice
end

# Read one whole frame off `io` as {opcode, payload}.
private def read_message(io : IO) : {UInt8, String}
  h = WS.read_header(io).not_nil!
  f = WS.read_body(io, h).not_nil!
  {h.opcode, String.new(f.payload)}
end

describe Gori::Proxy::WS::MessageGate do
  it "keeps PING/PONG and the opposite direction flowing while a message is held" do
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      # Requests-only, so the server → client leg is not gated at all and its liveness is
      # unambiguous. The both-directions case is the next example.
      ic.set_direction(Gori::Interceptor::Direction::RequestOnly)
      spawn { WS::Relay.run(r.client, r.upstream, 21_i64, sink, nil, HOLD_CTX, ic) }

      r.cs_w.write(masked(WS::OP_TEXT, "hold-me".to_slice))
      wait_until("the message to be held") { ic.pending_count == 1 }

      # RFC 6455 §5.4: a control frame may arrive between the fragments of a message, and the
      # pump forwards it the instant it does. If the hold blocked the pump this read hangs —
      # which is exactly how a real server's ping timer would close the socket while the
      # operator is still reading. THIS is why the WS pump may not block; h2's "other streams
      # keep moving" has no analogue on a socket with one stream.
      r.cs_w.write(masked(WS::OP_PING, "keepalive".to_slice))
      read_message(r.ts_r).should eq({WS::OP_PING, "keepalive"})

      # Full duplex: the two pumps are independent, so a hold on one direction charges the
      # other nothing — including the server's own PING, which the client must be able to
      # answer.
      r.ss_w.write(WS.encode(WS::OP_PING, "srv".to_slice, mask: false))
      read_message(r.tc_r).should eq({WS::OP_PING, "srv"})
      r.ss_w.write(WS.encode(WS::OP_TEXT, "from-server".to_slice, mask: false))
      read_message(r.tc_r).should eq({WS::OP_TEXT, "from-server"})

      # ... and only NOW does the held message move.
      item = ic.pending.first
      item.kind.should eq(Gori::Interceptor::Kind::WsOut)
      ic.forward(item.id)
      read_message(r.ts_r).should eq({WS::OP_TEXT, "hold-me"})
      ic.pending_count.should eq(0)
    end
    r.shutdown
  end

  it "keeps the two directions' queues independent — a hold on one blocks only itself" do
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic| # direction Both: each leg gets its own gate
      spawn { WS::Relay.run(r.client, r.upstream, 33_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(masked(WS::OP_TEXT, "to-server".to_slice))
      r.ss_w.write(WS.encode(WS::OP_TEXT, "to-client".to_slice, mask: false))
      wait_until("both directions to hold") { ic.pending_count == 2 }

      inbound = ic.pending.find! { |it| it.kind.ws_in? }
      ic.forward(inbound.id)
      # Released while the client → server message is still the operator's: a direction is one
      # ordering domain, and the other direction is not in it.
      read_message(r.tc_r).should eq({WS::OP_TEXT, "to-client"})
      ic.pending_count.should eq(1)

      ic.forward(ic.pending.first.id)
      read_message(r.ts_r).should eq({WS::OP_TEXT, "to-server"})
    end
    r.shutdown
  end

  it "holds nothing at all when the condition has no proto:ws term" do
    # The inverse of the HTTP default, and the whole of design D1: a blank filter matches
    # everything and still arms no WS hold, and neither does an ordinary host condition that
    # WOULD match this socket. Getting this wrong freezes every socket on the host at once.
    {"", "host:echo.test", "-proto:ws"}.each do |query|
      r = rig
      sink = HoldSink.new
      with_interceptor(query) do |ic|
        spawn { WS::Relay.run(r.client, r.upstream, 22_i64, sink, nil, HOLD_CTX, ic) }
        r.cs_w.write(masked(WS::OP_TEXT, "straight-through".to_slice))
        # It arrives without anyone deciding anything.
        read_message(r.ts_r).should eq({WS::OP_TEXT, "straight-through"})
        ic.pending_count.should eq(0)
      end
      r.shutdown
    end
  end

  it "narrows with body:, which matches only here — an HTTP gate has no bytes yet" do
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws body:subscribe") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 23_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(masked(WS::OP_TEXT, %({"op":"ping"}).to_slice))
      read_message(r.ts_r).should eq({WS::OP_TEXT, %({"op":"ping"})}) # no match → straight through
      r.cs_w.write(masked(WS::OP_TEXT, %({"op":"subscribe"}).to_slice))
      wait_until("the matching message to be held") { ic.pending_count == 1 }
      ic.forward(ic.pending.first.id)
      read_message(r.ts_r).should eq({WS::OP_TEXT, %({"op":"subscribe"})})
    end
    r.shutdown
  end

  it "sends the operator's edited bytes, re-framed as one frame and re-masked" do
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 24_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(masked(WS::OP_TEXT, %({"amount":1}).to_slice))
      wait_until("the hold") { ic.pending_count == 1 }
      ic.forward(ic.pending.first.id, %({"amount":9999}).to_slice)

      h = WS.read_header(r.ts_r).not_nil!
      h.fin?.should be_true
      h.masked?.should be_true # §5.3: every client → server frame is masked, with gori's key
      String.new(WS.read_body(r.ts_r, h).not_nil!.payload).should eq(%({"amount":9999}))
      # P7: the capture is what gori WROTE, not what arrived.
      sink.messages.should eq([{"out", 1, %({"amount":9999})}])
    end
    r.shutdown
  end

  it "writes nothing at all for a dropped message — invisible to both endpoints" do
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 25_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(masked(WS::OP_TEXT, "secret".to_slice))
      wait_until("the hold") { ic.pending_count == 1 }
      ic.drop(ic.pending.first.id)

      # No RST, no gap, no error: a WS stream has no message identity for a peer to notice a
      # hole in. The proof is that the NEXT message arrives as the first thing on the wire.
      r.cs_w.write(masked(WS::OP_TEXT, "next".to_slice))
      wait_until("the follow-up hold") { ic.pending_count == 1 }
      ic.forward(ic.pending.first.id)
      read_message(r.ts_r).should eq({WS::OP_TEXT, "next"})
      sink.messages.should eq([{"out", 1, "next"}]) # the dropped one was never captured either
    end
    r.shutdown
  end

  it "releases in ARRIVAL order however the operator decides them" do
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 26_i64, sink, nil, HOLD_CTX, ic) }
      %w(one two three).each { |m| r.cs_w.write(masked(WS::OP_TEXT, m.to_slice)) }
      wait_until("all three to be held") { ic.pending_count == 3 }

      held = ic.pending.sort_by(&.id)
      String.new(held[0].raw).should eq("one")
      # Decide the LAST one first, then the middle, then the head. The gate parks each
      # decision until everything ahead of it is decided — so nothing moves until "one" is.
      ic.forward(held[2].id)
      ic.forward(held[1].id)
      sleep 20.milliseconds
      ic.pending_count.should eq(1) # "one" is still the operator's

      ic.forward(held[0].id)
      read_message(r.ts_r).should eq({WS::OP_TEXT, "one"})
      read_message(r.ts_r).should eq({WS::OP_TEXT, "two"})
      read_message(r.ts_r).should eq({WS::OP_TEXT, "three"})
    end
    r.shutdown
  end

  it "orders a drop with the rest — a dropped message leaves a hole, not a reorder" do
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 27_i64, sink, nil, HOLD_CTX, ic) }
      %w(a b c).each { |m| r.cs_w.write(masked(WS::OP_TEXT, m.to_slice)) }
      wait_until("all three to be held") { ic.pending_count == 3 }
      held = ic.pending.sort_by(&.id)
      ic.forward(held[2].id)
      ic.drop(held[1].id)
      ic.forward(held[0].id)
      read_message(r.ts_r).should eq({WS::OP_TEXT, "a"})
      read_message(r.ts_r).should eq({WS::OP_TEXT, "c"})
    end
    r.shutdown
  end

  it "holds a BINARY message and marks it read-only rather than editable" do
    r = rig
    sink = HoldSink.new
    payload = Bytes[0x00, 0xFF, 0x10, 0x82] # not valid UTF-8: the DEFAULT case on opcode 2
    with_interceptor("proto:ws") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 28_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(masked(WS::OP_BIN, payload))
      wait_until("the binary hold") { ic.pending_count == 1 }
      item = ic.pending.first
      item.binary?.should be_true
      item.raw.should eq(payload)
      ic.forward(item.id)
      op, _ = read_message(r.ts_r)
      op.should eq(WS::OP_BIN)
      sink.messages.first[1].should eq(WS::OP_BIN.to_i)
    end
    r.shutdown
  end

  it "resolves the direction's queue when a CLOSE arrives on it (design D5)" do
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 29_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(masked(WS::OP_TEXT, "undecided".to_slice))
      wait_until("the hold") { ic.pending_count == 1 }

      # §5.5.1 forbids data frames after a Close, so the held message cannot be delivered
      # after it — it goes out FIRST, unedited, and the queue row is handed back. Forward
      # rather than drop: the peer hung up, and a peer is not the human P4 defers to.
      r.cs_w.write(masked(WS::OP_CLOSE, "bye".to_slice))
      read_message(r.ts_r).should eq({WS::OP_TEXT, "undecided"})
      read_message(r.ts_r).first.should eq(WS::OP_CLOSE)
      wait_until("the queue row to be given back") { ic.pending_count == 0 }
    end
    r.shutdown
  end

  it "releases an unedited FRAGMENTED message as the peer's own frames, byte-exact" do
    # A hold arms the assembling pump for every message on the direction, so this is the
    # rewrite path's defect reached through the other door: both fragments were buffered and
    # re-emitted as ONE frame with a mask key gori invented, for a message the operator
    # forwarded untouched. `Slot#raw` only ever carried a single frame.
    first = masked(WS::OP_TEXT, "frag-".to_slice, fin: false)
    second = masked(WS::OP_CONT, "tail".to_slice)
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 34_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(first)
      r.cs_w.write(second)
      wait_until("the hold") { ic.pending_count == 1 }
      ic.forward(ic.pending.first.id)

      got = Bytes.new(first.size + second.size)
      # A re-framed release is SHORTER than the two frames, so bound the read: the example
      # must fail, not hang the suite.
      r.ts_r.as(IO::FileDescriptor).read_timeout = 3.seconds
      r.ts_r.read_fully(got)
      got.should eq(first + second)
      sink.messages.should eq([{"out", 1, "frag-tail"}])
    end
    r.shutdown
  end

  # Arming a `proto:ws` catch puts EVERY message on this direction through the assembling
  # pump, including the ones the condition declines. Those are written through untouched, so
  # they have to reach the origin exactly as they arrived — a PING that sat between two
  # fragments included. `host:nosuchhost` narrows nothing (`arms_ws_hold?` tests the host
  # coarsely), which is precisely how an operator arms this by accident.
  it "keeps an interleaved PING in place for a message the condition declines" do
    first = masked(WS::OP_TEXT, "AAA".to_slice, fin: false)
    ping = masked(WS::OP_PING, "pi".to_slice)
    second = masked(WS::OP_CONT, "BBB".to_slice)
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws body:never-matches-this") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 51_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(first)
      r.cs_w.write(ping)
      r.cs_w.write(second)

      got = Bytes.new(first.size + ping.size + second.size)
      r.ts_r.as(IO::FileDescriptor).read_timeout = 3.seconds
      r.ts_r.read_fully(got)
      got.should eq(first + ping + second)
      ic.pending_count.should eq(0)
    end
    r.shutdown
  end

  # And the one place the interleave is deliberately given up. A message the operator is
  # actually holding may not sit on the peer's PONG — that is the liveness argument
  # `MessageGate`'s header is built on — so the control frame overtakes it, exactly once, and
  # the message's own frames follow on release with the control frame NOT duplicated.
  it "lets an interleaved PING overtake a message that is really held, and only then" do
    first = masked(WS::OP_TEXT, "hold".to_slice, fin: false)
    ping = masked(WS::OP_PING, "pi".to_slice)
    second = masked(WS::OP_CONT, "-me".to_slice)
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 52_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(first)
      r.cs_w.write(ping)
      r.cs_w.write(second)
      wait_until("the hold") { ic.pending_count == 1 }

      # The PING is already through while the message is still parked: a peer's ping timer
      # cannot be made to wait for a human.
      r.ts_r.as(IO::FileDescriptor).read_timeout = 3.seconds
      early = Bytes.new(ping.size)
      r.ts_r.read_fully(early)
      early.should eq(ping)

      ic.forward(ic.pending.first.id)
      released = Bytes.new(first.size + second.size)
      r.ts_r.read_fully(released)
      released.should eq(first + second) # the peer's own frames, and the PING not sent twice
      sink.messages.should eq([{"out", 9, "pi"}, {"out", 1, "hold-me"}])
    end
    r.shutdown
  end

  # #554's control-frame parking turned a DELIVERED keepalive into a lost one. `TEXT fin=0
  # "SECRET"` / `PING` / a socket that ends with NO close frame is a half-sent-secret test,
  # and both the byte-exact pump and the rewrite-only pump put both frames on the wire. On a
  # GATED socket neither left: `AssemblingPump#run`'s `ensure` skipped the flush whenever a
  # gate was armed, so `@parked` and `@buffer` were discarded — while capture still carried
  # the arrival row for the PING that never went out and NO row for the fragment that did.
  # The evidence was exactly inverted, and losing a keepalive on a gated socket is the very
  # liveness failure `MAX_PARKED_CONTROLS` and this class's header exist to prevent.
  #
  # The condition here matches NOTHING, which is the worst case and the way an operator arms
  # this by accident: they caught the socket for something else entirely.
  it "delivers a parked control frame and the fragment it sat inside when a gated socket ends with no CLOSE" do
    first = masked(WS::OP_TEXT, "SECRET".to_slice, fin: false)
    ping = masked(WS::OP_PING, "zz".to_slice)
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws body:never-matches-this") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 60_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(first)
      r.cs_w.write(ping)
      # The arrival row proves the PING has been read and parked; only then is the teardown
      # racing the thing under test.
      wait_until("the PING to be parked") { sink.messages.size == 1 }
      r.cs_w.close # the client vanishes mid-message: no CLOSE frame, no FIN

      r.ts_r.as(IO::FileDescriptor).read_timeout = 3.seconds
      r.ts_r.gets_to_end.to_slice.should eq(first + ping) # was: nothing at all
      # ... and the capture now says what the wire says, in the same order.
      sink.messages.should eq([{"out", 9, "zz"}, {"out", 1, "SECRET"}])
      ic.pending_count.should eq(0)
    end
    r.shutdown
  end

  # The complement: the same frames on the same gated socket, ended by a real CLOSE. That
  # path already flushed (via `forward_control`'s close branch) and must not now flush twice
  # — the teardown pass is idempotent, and the CLOSE still comes last (§5.5.1).
  it "still delivers the parked frame exactly once when the gated socket ends WITH a CLOSE" do
    first = masked(WS::OP_TEXT, "SECRET".to_slice, fin: false)
    ping = masked(WS::OP_PING, "zz".to_slice)
    bye = masked(WS::OP_CLOSE, Bytes[0x03, 0xe8])
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws body:never-matches-this") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 61_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(first)
      r.cs_w.write(ping)
      r.cs_w.write(bye)

      # Bounded read, not `gets_to_end`: a CLOSE is a CLEAN end, so `Relay.run` gives the
      # other direction its CLOSE_TIMEOUT window before it closes this writer.
      want = first + ping + bye
      got = Bytes.new(want.size)
      r.ts_r.as(IO::FileDescriptor).read_timeout = 3.seconds
      r.ts_r.read_fully(got)
      got.should eq(want)
      sink.messages[0, 2].should eq([{"out", 9, "zz"}, {"out", 1, "SECRET"}])
      sink.messages.size.should eq(3) # ... and the CLOSE, once
    end
    r.shutdown
  end

  # Ordering across the two teardown resolutions: a message a human really owns is released
  # by `settle` FIRST, and the half-assembled fragments the pump is withholding — which
  # arrived after it — follow. Getting this backwards would put later bytes on the wire ahead
  # of earlier ones on the one socket where order is the whole guarantee.
  it "releases a genuinely held message before the fragments still assembling behind it" do
    tail = masked(WS::OP_TEXT, "TAIL".to_slice, fin: false)
    ping = masked(WS::OP_PING, "zz".to_slice)
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      ic.set_direction(Gori::Interceptor::Direction::RequestOnly)
      spawn { WS::Relay.run(r.client, r.upstream, 62_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(masked(WS::OP_TEXT, "HELD".to_slice))
      wait_until("the hold") { ic.pending_count == 1 }
      # A second message starts behind the hold and never FINs, with a PING inside it.
      r.cs_w.write(tail)
      r.cs_w.write(ping)
      wait_until("the PING to be parked") { sink.messages.size == 1 }
      r.cs_w.close

      r.ts_r.as(IO::FileDescriptor).read_timeout = 3.seconds
      got = r.ts_r.gets_to_end.to_slice
      got.should eq(masked(WS::OP_TEXT, "HELD".to_slice) + tail + ping)
      sink.messages.should eq([{"out", 9, "zz"}, {"out", 1, "HELD"}, {"out", 1, "TAIL"}])
    end
    r.shutdown
  end

  it "forwards a still-held message at teardown instead of destroying it" do
    # The socket ends while the operator still owns the message. `MessageGate#close` runs
    # from the pump's `ensure`, which is only reached AFTER `Relay.run` has closed both
    # sockets to unblock the pump's read — so releasing there writes to a dead socket. It
    # also set `@closed` BEFORE handing the item back, so the wait fiber returned at
    # `resolve_locked`'s `return if @closed` and the bytes reached neither socket and no
    # `ws_messages` row, under a log line calling them "released". `Relay.run` settles both
    # gates while the sockets are still open; fail-open is the disposition every other
    # involuntary release in this class already takes.
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      ic.set_direction(Gori::Interceptor::Direction::RequestOnly)
      spawn { WS::Relay.run(r.client, r.upstream, 35_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(masked(WS::OP_TEXT, "CLIENT-HELD".to_slice))
      wait_until("the hold") { ic.pending_count == 1 }

      r.ss_w.close # the origin goes away with the decision still outstanding
      read_message(r.ts_r).should eq({WS::OP_TEXT, "CLIENT-HELD"})
      wait_until("the queue row to be given back") { ic.pending_count == 0 }
      sink.messages.should eq([{"out", 1, "CLIENT-HELD"}])
    end
    r.shutdown
  end

  it "releases what it is holding on #close, before it shuts its own writers down" do
    # `close` reached directly, without `Relay.run`'s settle in front of it, because the
    # ORDER inside it was its own defect: `@closed = true` ran first, so the wait fiber woken
    # by the `forward` below hit `resolve_locked`'s `return if @closed` and the bytes were
    # written nowhere. `@dst` here is live, so a release that happens lands visibly.
    dst = IO::Memory.new
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      gate = WS::MessageGate.new("out", dst, 36_i64, sink, ic, HOLD_CTX, mask: true)
      gate.submit(WS::OP_TEXT, "held".to_slice, nil)
      wait_until("the hold") { ic.pending_count == 1 }
      gate.close
      dst.size.should_not eq(0) # was: zero bytes, and no capture row either
      read_message(IO::Memory.new(dst.to_slice)).should eq({WS::OP_TEXT, "held"})
      sink.messages.should eq([{"out", 1, "held"}])
      ic.pending_count.should eq(0)
    end
  end

  it "hands every still-held message back when the socket dies, leaving no ghost row" do
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 30_i64, sink, nil, HOLD_CTX, ic) }
      r.cs_w.write(masked(WS::OP_TEXT, "orphan".to_slice))
      wait_until("the hold") { ic.pending_count == 1 }
      # The peer vanishes with the operator still reading. `H2::StreamGate#close`'s contract:
      # the queue row is resolved and the wait fiber unblocked, or the TUI shows a hold whose
      # decision can never reach anything.
      r.cs_w.close
      r.ss_w.close
      wait_until("the queue to drain") { ic.pending_count == 0 }
    end
  end

  it "applies Match & Replace BEFORE the hold — one pipeline, not two" do
    # #513's D3, carried over: what the operator sees in the editor is what the rules
    # produced. Two pipelines would mean editing bytes the rules had not seen.
    r = rig
    sink = HoldSink.new
    rewriter = WsHoldRewriter.new({"alpha", "BETA"})
    with_interceptor("proto:ws") do |ic|
      spawn { WS::Relay.run(r.client, r.upstream, 31_i64, sink, rewriter, HOLD_CTX, ic) }
      r.cs_w.write(masked(WS::OP_TEXT, "alpha-1".to_slice))
      wait_until("the hold") { ic.pending_count == 1 }
      item = ic.pending.first
      String.new(item.raw).should eq("BETA-1") # the rule already ran
      ic.forward(item.id)
      read_message(r.ts_r).should eq({WS::OP_TEXT, "BETA-1"})
    end
    r.shutdown
  end

  it "holds the in direction when the catch direction allows it, and not when it does not" do
    r = rig
    sink = HoldSink.new
    with_interceptor("proto:ws") do |ic|
      ic.set_direction(Gori::Interceptor::Direction::ResponseOnly)
      spawn { WS::Relay.run(r.client, r.upstream, 32_i64, sink, nil, HOLD_CTX, ic) }
      # out (client → server) is the request leg: responses-only lets it straight through.
      r.cs_w.write(masked(WS::OP_TEXT, "to-server".to_slice))
      read_message(r.ts_r).should eq({WS::OP_TEXT, "to-server"})
      # in (server → client) is held.
      r.ss_w.write(WS.encode(WS::OP_TEXT, "to-client".to_slice, mask: false))
      wait_until("the in-direction hold") { ic.pending_count == 1 }
      item = ic.pending.first
      item.kind.should eq(Gori::Interceptor::Kind::WsIn)
      ic.forward(item.id)
      h = WS.read_header(r.tc_r).not_nil!
      h.masked?.should be_false # server → client is never masked
      String.new(WS.read_body(r.tc_r, h).not_nil!.payload).should eq("to-client")
    end
    r.shutdown
  end
end

# A Match & Replace lens that only rewrites the client → server direction.
private class WsHoldRewriter < Gori::Proxy::HeadRewriter
  def initialize(@pair : {String, String})
  end

  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end

  def rewrites_ws_out_for_host?(host : String) : Bool
    true
  end

  def rewrite_ws_out(payload : Bytes, host : String) : Bytes
    text = String.new(payload)
    return payload unless text.valid_encoding?
    out = text.gsub(@pair[0], @pair[1])
    out == text ? payload : out.to_slice
  end
end
