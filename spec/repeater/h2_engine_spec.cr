require "../spec_helper"
require "socket"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

# A minimal cleartext-h2 origin: reads the preface + request, records the decoded
# request line and body, then replies SETTINGS + HEADERS(:status) + DATA.
# An origin that accepts the TCP connection and nothing more. The refusal examples below never
# write a request, so the h2-speaking origin's `read_preface` would hit EOF and print an
# unhandled-spawn backtrace into the spec output — noise that reads like a failure. All these
# examples need is a port `H2Engine.open` can connect to.
private def start_quiet_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    conn = origin.accept?
    conn.try(&.close) rescue nil
  end
  port
end

private def start_h2_origin(status : Int32, body : String, seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    dec = HPACK::Decoder.new
    method = path = ""
    req_body = IO::Memory.new
    headers_done = false
    loop do
      f = Frame.read(conn)
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers
        if f.stream_id == 1 && f.end_headers?
          dec.decode(f.payload).each do |(n, v)|
            method = v if n == ":method"
            path = v if n == ":path"
          end
          headers_done = true
          break if f.end_stream?
        end
      when Frame::Type::Data
        req_body.write(f.payload) if f.stream_id == 1
        break if f.end_stream?
      else
        # ignore SETTINGS/WINDOW_UPDATE from the client
      end
    end
    seen.send("#{method} #{path} body=#{req_body}")

    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    status_block = HPACK::Encoder.new.encode([{":status", status.to_s}, {"server", "gori-test"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, status_block).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, body.to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that records the decoded `:authority` pseudo-header of the
# request (so a test can assert what authority the client actually put on the wire).
private def start_h2_origin_authority(status : Int32, seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    dec = HPACK::Decoder.new
    authority = "(none)"
    loop do
      f = Frame.read(conn)
      break if f.nil?
      if f.frame_type == Frame::Type::Headers && f.stream_id == 1 && f.end_headers?
        dec.decode(f.payload).each { |(n, v)| authority = v if n == ":authority" }
        break if f.end_stream?
      elsif f.frame_type == Frame::Type::Data && f.end_stream?
        break
      end
    end
    seen.send(authority)
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    sb = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, "ok".to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that sends HEADERS(:status) + one DATA frame WITHOUT
# END_STREAM, then drops the connection — a truncated response the client must
# flag as incomplete (no END_STREAM ever arrives).
private def start_h2_origin_truncated(status : Int32, partial : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    block = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, block).to_bytes)
    # DATA WITHOUT END_STREAM, then close mid-stream.
    conn.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32, partial.to_slice).to_bytes)
    conn.flush
    conn.close
  end
  port
end

# A cleartext-h2 origin that ENFORCES flow control: it sends `body` as DATA frames
# but never exceeds the available connection/stream window (both start at the 65535
# default), blocking for the client's WINDOW_UPDATE frames to replenish. A client
# that never sends WINDOW_UPDATE stalls past 65535 bytes (the bug this guards).
private def start_h2_origin_flow_controlled(status : Int32, body : Bytes) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    # drain to the request's END_STREAM (a body-less GET)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type == Frame::Type::Headers && f.stream_id == 1 && f.end_stream?
    end
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    sb = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
    conn.flush

    conn_win = 65535
    stream_win = 65535
    offset = 0
    begin
      while offset < body.size
        while conn_win <= 0 || stream_win <= 0
          f = Frame.read(conn)
          break if f.nil?
          next unless f.frame_type == Frame::Type::WindowUpdate
          inc = (IO::ByteFormat::BigEndian.decode(UInt32, f.payload) & 0x7fff_ffff).to_i
          f.stream_id == 0 ? (conn_win += inc) : (stream_win += inc)
        end
        n = {16384, body.size - offset, conn_win, stream_win}.min
        last = offset + n >= body.size
        conn.write(Frame::Header.new(Frame::Type::Data.value, last ? Frame::END_STREAM : 0_u8, 1_u32, body[offset, n]).to_bytes)
        conn.flush
        conn_win -= n
        stream_win -= n
        offset += n
      end
      sleep 0.2.seconds
    rescue
    end
    conn.close
  end
  port
end

# An origin that interleaves PING frames (no END_STREAM) before the real response — the
# non-terminal-frame path the MAX_FRAMES counter now guards. A handful must be ACKed and
# must NOT stall or corrupt the response.
private def start_h2_origin_pings(status : Int32, body : String, pings : Int32) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    pings.times { conn.write(Frame::Header.new(Frame::Type::Ping.value, 0_u8, 0_u32, Bytes.new(8)).to_bytes) }
    sb = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, body.to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that records the request's DECODED FIELD LIST verbatim and the
# {type, payload size} of every frame that carried the header block. The existing origins
# project the request down to `"#{method} #{path}"`, which cannot see the two things this
# file's newest examples are about: which regular fields survived the encoder, and whether
# the block went out as one over-size HEADERS or as HEADERS + CONTINUATION.
private def start_h2_origin_recording(seen : Channel({Array({String, String}), Array({String, Int32})})) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    dec = HPACK::Decoder.new
    block = IO::Memory.new
    shape = [] of {String, Int32}
    fields = [] of {String, String}
    # END_STREAM rides the HEADERS frame while END_HEADERS rides the LAST CONTINUATION, so
    # neither flag alone ends a split request — latch the first and wait for the second.
    end_stream = false
    loop do
      f = Frame.read(conn)
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers, Frame::Type::Continuation
        next unless f.stream_id == 1
        shape << {f.frame_type.to_s, f.payload.size}
        block.write(f.payload)
        end_stream ||= f.end_stream?
        if f.end_headers?
          dec.decode(block.to_slice).each { |(n, v)| fields << {n, v} }
          break if end_stream
        end
      when Frame::Type::Data
        break if f.end_stream?
      else
        # SETTINGS / WINDOW_UPDATE from the client
      end
    end
    seen.send({fields, shape})

    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    sb = HPACK::Encoder.new.encode([{":status", "200"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, "ok".to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that answers the first HEADERS with GOAWAY(`code`) + debug data and
# hangs up, the way a real stack rejects a frame it will not accept.
private def start_h2_origin_goaway(code : UInt32, debug : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      next unless f.frame_type == Frame::Type::Headers
      payload = IO::Memory.new
      payload.write_bytes(0_u32, IO::ByteFormat::BigEndian) # last-stream-id
      payload.write_bytes(code, IO::ByteFormat::BigEndian)
      payload.write(debug.to_slice)
      conn.write(Frame::Header.new(Frame::Type::Goaway.value, 0_u8, 0_u32, payload.to_slice).to_bytes)
      conn.flush
      break
    end
    conn.close
  end
  port
end

describe Gori::Repeater::H2Engine do
  it "repeaters a GET as real cleartext h2 and reassembles the response" do
    seen = Channel(String).new(1)
    port = start_h2_origin(200, "replayed!", seen)

    request = "GET /api/thing HTTP/2\r\nx-repeater: yes\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq("GET /api/thing body=") # origin saw the HPACK-encoded request
    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200)
    String.new(result.head).should contain("HTTP/2 200")
    String.new(result.head).should contain("server: gori-test")
    String.new(result.body.not_nil!).should eq("replayed!")
    result.incomplete?.should be_false # END_STREAM was seen — a complete response
  end

  # The Fuzzer marks a position inside a header VALUE. `parse_request` rebuilds the h2 fields
  # from the h1 text by splitting on '\n', so a payload carrying a bare LF split the field and
  # the orphan tail hit a `next unless colon` — `x-fuzz: be\naf` went out as `x-fuzz: be` while
  # the result row was still labelled with the whole payload. The operator then reads a status
  # measured against a request gori never sent. Measured at the wire against an HPACK-decoding
  # origin before the fix. h1 carries these bytes verbatim (P7); h2 has no encoding for them,
  # so refusing is the only answer that does not lie.
  it "refuses a header value carrying a bare LF rather than silently dropping the tail" do
    port = start_quiet_origin

    request = "GET /f HTTP/2\r\nx-fuzz: be\naf\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    result.ok?.should be_false
    result.error.not_nil!.should contain("not a header field")
    result.error.not_nil!.should contain("HTTP/2")
  end

  it "refuses a lone CR inside a header value (rstrip only ever removed a trailing one)" do
    port = start_quiet_origin

    request = "GET /f HTTP/2\r\nx-fuzz: x\ry\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    result.ok?.should be_false
    result.error.not_nil!.should contain("CR, LF or NUL")
  end

  it "refuses a NUL inside a header value" do
    port = start_quiet_origin

    request = "GET /f HTTP/2\r\nx-fuzz: nul\u0000byte\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    result.ok?.should be_false
    result.error.not_nil!.should contain("CR, LF or NUL")
  end

  # The deliberate non-case: a CRLF that yields two WELL-FORMED fields is indistinguishable
  # from the operator typing two headers, and the h1 engine puts two headers on the wire for
  # it too. Refusing that would break the smuggling primitive P7 exists to preserve.
  it "still sends a CRLF that parses as two well-formed header fields" do
    seen = Channel(String).new(1)
    port = start_h2_origin(200, "ok", seen)

    request = "GET /f HTTP/2\r\nx-a: one\r\nx-b: two\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    seen.receive.should eq("GET /f body=")
    result.ok?.should be_true
  end

  it "flags an h2 response cut short before END_STREAM as incomplete" do
    port = start_h2_origin_truncated(200, "partial")

    request = "GET /trunc HTTP/2\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_true # a status + partial body did arrive
    result.response.not_nil!.status.should eq(200)
    String.new(result.body.not_nil!).should eq("partial") # what arrived is captured
    result.incomplete?.should be_true                     # but no END_STREAM — incomplete
  end

  it "sends a request body as DATA frames" do
    seen = Channel(String).new(1)
    port = start_h2_origin(201, "created", seen)

    request = "POST /submit HTTP/2\r\ncontent-type: text/plain\r\n\r\nhello-h2-body".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq("POST /submit body=hello-h2-body")
    result.response.not_nil!.status.should eq(201)
    String.new(result.body.not_nil!).should eq("created")
  end

  it "handles interleaved PING frames before the response without stalling" do
    port = start_h2_origin_pings(200, "pong-ok", 20)
    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200)
    String.new(result.body.not_nil!).should eq("pong-ok")
  end

  it "maps an edited Host header to :authority (h1↔h2 parity for host-confusion probes)" do
    seen = Channel(String).new(1)
    port = start_h2_origin_authority(200, seen)

    # Connect to 127.0.0.1 but CLAIM a different authority via the Host header — the
    # h2 engine must send :authority = the edited Host, not the dialed target.
    request = "GET / HTTP/2\r\nHost: victim.internal\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq("victim.internal")
    result.ok?.should be_true
  end

  it "falls back to the dialed host for :authority when no Host header is present" do
    seen = Channel(String).new(1)
    port = start_h2_origin_authority(200, seen)

    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq("127.0.0.1:#{port}")
    result.ok?.should be_true
  end

  it "reports an error when the origin is unreachable" do
    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: 1, verify_upstream: false)
    result.ok?.should be_false
    result.error.should_not be_nil
  end

  # gori has TWO h2 request encoders. The proxy's intercept-edit path puts these fields on
  # the wire; this one — which every scripted surface uses — dropped them from a `FORBIDDEN`
  # set and reported the resulting 200 as though they had been sent. The h2.TE / h2.CL
  # downgrade desync is DEFINED by putting `transfer-encoding` inside an h2 HEADERS block, so
  # the drop made the single most important h2 test inexpressible everywhere but the TUI's
  # live intercept editor.
  it "puts connection-specific headers on the h2 wire instead of dropping them" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    request = "POST /desync HTTP/2\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n" \
              "Upgrade: h2c\r\nKeep-Alive: timeout=5\r\nProxy-Connection: keep-alive\r\n\r\nx".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    fields, _ = seen.receive
    fields.should contain({"transfer-encoding", "chunked"})
    fields.should contain({"connection", "keep-alive"})
    fields.should contain({"upgrade", "h2c"})
    fields.should contain({"keep-alive", "timeout=5"})
    fields.should contain({"proxy-connection", "keep-alive"})
    result.ok?.should be_true
  end

  # RFC 9113 §8.2.1: a field value may not start or end with whitespace, and a conformant
  # peer must treat one that does as malformed. Whether a given CDN/target actually does is a
  # standard conformance probe — the encoder `strip`ped both sides, so the probe always came
  # back "accepted" having never left. The proxy's encoder kept it (`HeadCodec.header_field`),
  # which is the rule this one now shares.
  it "keeps a trailing space in a header value (the §8.2.1 probe)" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    request = "GET /pad HTTP/2\r\nX-Pad: trailing   \r\n\r\n".to_slice
    Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    fields, _ = seen.receive
    fields.should contain({"x-pad", "trailing   "})
  end

  # The leading OWS after the colon is h1 SYNTAX, not value — `lstrip(' ')` is right, and it
  # is the same cut the proxy encoder makes. Pinned so a later "fix everything verbatim" pass
  # cannot quietly start sending it.
  it "drops only the h1 syntactic space after the colon, not the value's own tail" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    Gori::Repeater::H2Engine.send("GET / HTTP/2\r\nx-lead:    lead\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    fields, _ = seen.receive
    fields.should contain({"x-lead", "lead"})
  end

  it "lowercases field names by default (an h1 paste must stay sendable over h2)" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    Gori::Repeater::H2Engine.send("GET / HTTP/2\r\nX-MiXeD-Case: KeepMe\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    fields, _ = seen.receive
    fields.should contain({"x-mixed-case", "KeepMe"}) # name folded, VALUE untouched
  end

  # What `--verbatim` / MCP `verbatim:true` buys on h2. The flag promised "the stored bytes
  # EXACTLY" and changed nothing this encoder does, so an operator was told the bytes were
  # exact when the names had been folded. An uppercase name is malformed h2 a conformant peer
  # must reject — which is the point of typing one.
  it "preserves field-name case under preserve_field_case" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    Gori::Repeater::H2Engine.send("GET / HTTP/2\r\nX-MiXeD-Case: KeepMe\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
      preserve_field_case: true)

    fields, _ = seen.receive
    fields.should contain({"X-MiXeD-Case", "KeepMe"})
  end

  # A version-less request line is what a parser-differential / HTTP-0.9 probe writes, and
  # what hand-editing the line in the TUI editor produces. The encoder's own copy of the
  # request-line rule cut at the LAST space unconditionally, so `last_sp == first_sp` fell
  # through to `"/"` — gori reported a normal 200 for a URL the operator never asked for.
  # `HeadCodec.request_line` (now shared) strips the trailing token only when it is a version.
  it "keeps the path when the request line carries no HTTP/x version token" do
    seen = Channel(String).new(1)
    port = start_h2_origin(200, "ok", seen)

    result = Gori::Repeater::H2Engine.send("GET /noversion\r\nx-case: a\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq("GET /noversion body=")
    result.ok?.should be_true
  end

  # RFC 9113 §4.2 caps EVERY frame at the peer's SETTINGS_MAX_FRAME_SIZE, whose initial value
  # (§6.5.2) is 2^14 and which may never be set lower — so 16384 is safe against every peer
  # and needs no round trip. The old code wrote the whole block as one HEADERS frame because
  # MAX_FRAME had been read as a DATA-only concern; a large cookie jar, a JWT, or a
  # header-size probe therefore produced an illegal frame that strict origins answered with
  # GOAWAY(FRAME_SIZE_ERROR).
  it "splits an over-size header block into HEADERS + CONTINUATION at MAX_FRAME" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    request = "GET /big HTTP/2\r\nx-big: #{"A" * 30_000}\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    fields, shape = seen.receive
    shape.size.should be > 1
    shape.first[0].should eq("Headers")
    shape[1..].each { |(type, _)| type.should eq("Continuation") }
    shape.each { |(_, size)| size.should be <= Gori::Repeater::H2Engine::MAX_FRAME }
    fields.should contain({"x-big", "A" * 30_000}) # and it still decodes as one field
    result.ok?.should be_true
  end

  # A GOAWAY is the origin naming the reason it hung up (§6.8), and it is usually about the
  # bytes GORI sent. The code was read only as "stop looping", so the operator got "no h2
  # response" and went looking at the network.
  it "reports a GOAWAY error code and debug data instead of 'no h2 response'" do
    port = start_h2_origin_goaway(6_u32, "frame too large")

    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_false
    error = result.error.not_nil!
    error.should contain("GOAWAY")
    error.should contain("FRAME_SIZE_ERROR")
    error.should contain("frame too large")
  end

  # The refusal fires on the `colon == 0` guard, but its message blamed a CR, LF or NUL —
  # bytes the line does not contain — so the operator went hunting for an invisible control
  # character. The refusal itself is correct and stays.
  it "names the pseudo-header, not a phantom CR/LF/NUL, when refusing `:scheme: http`" do
    port = start_quiet_origin

    result = Gori::Repeater::H2Engine.send("GET /p HTTP/2\r\n:scheme: http\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_false
    error = result.error.not_nil!
    error.should contain("pseudo-header")
    error.should_not contain("CR, LF or NUL")
  end

  describe ".encoded_request" do
    # Every "the request actually put on the wire" report was derived from the operator's
    # TEXT, which on the h2 path is only an input: the encoder resolves `:path` from the
    # request line, folds `Host:` into `:authority` and lowercases names. MCP therefore
    # answered `target: "/mcp-noversion"` with `Transfer-Encoding` in the recorded head while
    # `GET /` had gone out, and `run show --format raw` printed those same bytes back.
    it "projects the ENCODED fields, not the source text" do
      source = "GET /noversion\r\nHost: claimed.example\r\nX-MiXeD: Keep\r\n" \
               "Transfer-Encoding: chunked\r\n\r\n".to_slice
      wire = String.new(Gori::Repeater::H2Engine.encoded_request(source,
        scheme: "https", host: "127.0.0.1", port: 8443))

      wire.should start_with("GET /noversion HTTP/2\r\n")
      wire.should contain("Host: claimed.example\r\n") # the :authority actually encoded
      wire.should contain("x-mixed: Keep\r\n")         # folded, as the wire has it
      wire.should contain("transfer-encoding: chunked\r\n")
    end

    it "carries the body through unchanged" do
      wire = String.new(Gori::Repeater::H2Engine.encoded_request(
        "POST /p HTTP/2\r\ncontent-length: 5\r\n\r\nhello".to_slice,
        scheme: "http", host: "h", port: 80))
      wire.should end_with("\r\n\r\nhello")
    end

    it "reports the preserved case when the send will preserve it" do
      wire = String.new(Gori::Repeater::H2Engine.encoded_request(
        "GET / HTTP/2\r\nX-MiXeD: Keep\r\n\r\n".to_slice,
        scheme: "http", host: "h", port: 80, preserve_field_case: true))
      wire.should contain("X-MiXeD: Keep\r\n")
    end
  end

  it "credits flow-control windows so a response past the default window completes" do
    body = Bytes.new(100_000) { |i| (65 + i % 26).to_u8 } # 100 KB > the 65535 window
    port = start_h2_origin_flow_controlled(200, body)

    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\nhost: 127.0.0.1\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_true # would time out (incomplete) without WINDOW_UPDATE
    result.response.not_nil!.status.should eq(200)
    result.body.not_nil!.size.should eq(100_000)
  end
end
