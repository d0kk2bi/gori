require "../proxy/upstream"
require "../proxy/h2/frame"
require "../proxy/h2/hpack"
require "../proxy/h2/head_codec"
require "../proxy/codec/http1"
require "./engine"

module Gori
  module Repeater
    # Repeaters an h2 flow as real HTTP/2: opens a connection (TLS+ALPN "h2" for
    # https, or h2c prior-knowledge for http), HPACK-encodes the edited request,
    # exchanges frames on stream 1, and reassembles the response into the same
    # `Repeater::Result` the h1 engine produces (so the diff/view path is shared).
    #
    # One-shot and intentionally minimal: empty client SETTINGS (ACK on receipt),
    # PING answered. BOTH directions are flow-controlled. Response side: each DATA frame
    # is credited straight back with a WINDOW_UPDATE on the connection + stream, so
    # responses past the 65535-byte default window stream fine. Request side: the peer's
    # SETTINGS is read before the first DATA frame and inbound WINDOW_UPDATEs are applied
    # while the body is written, so a body larger than the peer's window blocks for credit
    # instead of overrunning it (see `SendFlow`).
    module H2Engine
      MAX_FRAME = 16384
      # RFC 9113 §6.9.2: the connection and every new stream start with a 65535-byte
      # flow-control window in each direction, until the peer says otherwise.
      DEFAULT_WINDOW = 65_535
      # Caps for the one-shot response read, mirroring the live assembler. Without
      # them a hostile/large origin could OOM the workbench: HEADERS/CONTINUATION
      # are NOT flow-controlled, so a CONTINUATION flood grows the header block
      # unboundedly, and a streaming/over-large body has no aggregate ceiling.
      MAX_HEADER_BLOCK = 1 << 20         # 1 MiB
      MAX_BODY         = 8 * 1024 * 1024 # 8 MiB (repeater response read ceiling; independent of the proxy-capture cap)
      # Hard ceiling on frames processed for one response. HEADERS/DATA are byte-capped
      # above, but non-terminal frames (PING/PRIORITY/WINDOW_UPDATE/SETTINGS on any stream)
      # are neither — a hostile origin can stream them forever without END_STREAM, and the
      # per-op io_timeout only fires on IDLE, so bytes-always-arriving pins the fiber. This
      # bounds the loop the way the h1 engine's MAX_INTERIM does (RFC-hostile-origin guard).
      MAX_FRAMES = 100_000

      private alias Frame = Proxy::H2::Frame
      private alias HPACK = Proxy::H2::HPACK
      private alias HeadCodec = Proxy::H2::HeadCodec

      # Request-direction (send-side) flow control, plus the frames the WRITER read while
      # waiting for window — `read_response` drains them first so nothing is lost.
      #
      # h2 flow control is bidirectional and this engine only ever implemented the receive
      # half. The send half was fire-and-forget: `write_data` blasted the whole body in
      # MAX_FRAME chunks with no accounting, so any request body past the peer's window drew
      # GOAWAY(FLOW_CONTROL_ERROR) — and the report named the ORIGIN for a violation that was
      # gori's own. Upload fuzzing, large JSON/GraphQL batches, protobuf payloads and
      # body-size probes are the ordinary work of this tool, so the old note that "repeater
      # bodies are typically small" was never true: no gori surface could send a >64 KiB h2
      # request body against any conformant origin.
      private class SendFlow
        property conn : Int64 = DEFAULT_WINDOW.to_i64
        property stream : Int64 = DEFAULT_WINDOW.to_i64
        # The peer's SETTINGS_INITIAL_WINDOW_SIZE as last applied. §6.9.2 makes a change a
        # DELTA against this value on every open stream, not an assignment — and the result
        # may legitimately go negative when the peer shrinks it after we have already sent.
        property initial : Int64 = DEFAULT_WINDOW.to_i64
        property? settings_seen = false
        # Stream 1 (or the whole connection) was closed by the peer — stop writing DATA and
        # go read what it said, rather than pushing a body at a stream that is already gone.
        property? closed = false
        # A read reached a clean EOF: nothing more will ever arrive on this socket.
        property? eof = false
        property goaway : String? = nil
        property rst : String? = nil
        getter pending = [] of Frame::Header
        # Shared with `read_response` so the MAX_FRAMES hostile-origin ceiling counts the
        # frames absorbed during the write too.
        property frames = 0

        # Bytes the peer will accept on stream 1 right now. Never negative: §6.9.2 lets a
        # SETTINGS shrink drive a window below zero, and that simply means "send nothing".
        def available : Int64
          m = conn < stream ? conn : stream
          m < 0 ? 0_i64 : m
        end
      end

      # What one response read produced. A record rather than a widening tuple: the read now
      # carries the peer's own stated reason (GOAWAY *or* RST_STREAM), which fields arrived in
      # a TRAILING header block, and how the read ended — and every one of those is a distinct
      # sentence the operator needs.
      private record Reply,
        status : Int32,
        headers : Array({String, String}),
        body : Bytes?,
        clean_eos : Bool,
        goaway : String?,
        rst : String?,
        trailers : Array(String)?,
        timed_out : Bool

      def self.send(request : Bytes, *, scheme : String, host : String, port : Int32,
                    verify_upstream : Bool, sni : String? = nil,
                    timeout : Time::Span? = nil,
                    overrides : Gori::HostOverrides? = nil,
                    preserve_field_case : Bool = false) : Result
        started = Time.instant
        upstream = open(scheme, host, port, verify_upstream, sni, timeout, overrides)
        return failure(connect_error(scheme, host, port, verify_upstream), started) unless upstream
        begin
          headers, body = parse_request(request, scheme, host, port, preserve_field_case)
          exchange(upstream, headers, body, host, port, started)
        rescue ex
          failure(ex.message || "h2 repeater error", started)
        ensure
          upstream.close rescue nil
        end
      end

      # Send a hand-authored request as its EXACT HPACK field list — the field-native path.
      #
      # `send`/`parse_request` derive the fields from HTTP/1.1 head TEXT, and that text
      # structurally cannot hold a duplicate pseudo-header, a pseudo AFTER a regular field, a
      # `:scheme` that disagrees with the connection, `:protocol` (RFC 8441 extended CONNECT),
      # an unknown pseudo, or a leading-space value — `HeadCodec.h1_faithful?` enumerates
      # exactly that loss set. A conformance / desync test is MADE of those shapes, so before
      # this an operator could express none of them on any scripted surface: the blocker was
      # the CARRIER, not the HPACK encoder, which encodes any of them without complaint.
      #
      # Here the fields ARE the message: they reach `write_request` verbatim, in the given
      # order, with no dedup, reorder, case-fold, strip, `reject_uncarriable`, or `:authority`/
      # `:scheme` injection — the operator owns every pseudo-header, so an OMITTED `:authority`
      # is the missing-authority probe, not a bug to repair. The default frame sequence
      # (PREFACE, SETTINGS, HEADERS[+CONTINUATION at MAX_FRAME], DATA) is unchanged: this
      # widens WHAT the HEADERS block carries, not HOW it is framed.
      def self.send_fields(fields : Array({String, String}), body : Bytes?, *, scheme : String,
                           host : String, port : Int32, verify_upstream : Bool, sni : String? = nil,
                           timeout : Time::Span? = nil, overrides : Gori::HostOverrides? = nil) : Result
        started = Time.instant
        upstream = open(scheme, host, port, verify_upstream, sni, timeout, overrides)
        return failure(connect_error(scheme, host, port, verify_upstream), started) unless upstream
        begin
          exchange(upstream, fields, body, host, port, started)
        rescue ex
          failure(ex.message || "h2 repeater error", started)
        ensure
          upstream.close rescue nil
        end
      end

      # Write the request, read the one-shot response, and shape it into a `Result`. Extracted
      # from `send` so the h1-text path and the field-native `send_fields` path share the exact
      # same exchange — the fields differ, the framing and reassembly do not.
      private def self.exchange(upstream : IO, headers : Array({String, String}), body : Bytes?,
                                host : String, port : Int32, started : Time::Instant) : Result
        flow = SendFlow.new
        write_request(upstream, headers, body, flow)
        reply = read_response(upstream, flow)
        return failure(no_response(reply, host, port), started) if reply.status == 0 && reply.headers.empty?
        head = synth_head(reply)
        resp = Proxy::Codec::Http1.parse_response_head(head)
        # A stream the peer RESET or a connection it sent GOAWAY on still produced bytes here,
        # and the cause must not be dropped just because a partial response arrived: a
        # RST_STREAM(CANCEL) after a 200 + half a body used to render as
        # "incomplete — origin closed before the framed body finished", which names the wrong
        # event entirely. The head and body stay on the Result; the reason rides alongside.
        reason = reply.rst || reply.goaway
        Result.new(head, reply.body, resp, elapsed(started),
          error: reason ? "#{reason} from #{host}:#{port}" : nil,
          incomplete: !reply.clean_eos, delivered: true)
      end

      # The one sentence that names why an h2 exchange produced no response.
      #
      # Seven distinct causes used to collapse into "no h2 response from HOST:PORT": each
      # RST_STREAM error code, a GOAWAY, an idle read timeout, and a socket that closed. A
      # WAF / rate-limiter test is MADE of telling ENHANCE_YOUR_CALM from REFUSED_STREAM from
      # a dead socket, and REFUSED_STREAM in particular is an explicit "retry on a new
      # connection" instruction (RFC 9113 §8.7) that was being reported as a flat refusal.
      # RST_STREAM is preferred over GOAWAY: it is about OUR stream, the GOAWAY that usually
      # follows is about the connection.
      private def self.no_response(reply : Reply, host : String, port : Int32) : String
        if reason = reply.rst || reply.goaway
          return "#{reason} from #{host}:#{port}"
        end
        # "sent nothing before the read timed out" is the genuinely retryable outcome and
        # "closed" is not; they had the same wording, so no consumer could tell them apart.
        return "no h2 response from #{host}:#{port} — the origin sent nothing before the read timed out" if reply.timed_out
        "no h2 response from #{host}:#{port} — the connection closed before a response frame arrived"
      end

      private def self.open(scheme : String, host : String, port : Int32, verify : Bool,
                            sni : String? = nil, timeout : Time::Span? = nil,
                            overrides : Gori::HostOverrides? = nil) : IO?
        ct = timeout || Settings.connect_timeout
        it = timeout || Settings.io_timeout
        if scheme == "https"
          ssl = Proxy::Upstream.dial_tls(host, port, verify: verify, alpn: "h2", sni: sni, connect_timeout: ct, io_timeout: it, overrides: overrides)
          return nil unless ssl
          # Origin completed the handshake but won't speak h2 — close the live
          # socket before bailing, else it leaks (it's never returned to `ensure`).
          unless ssl.alpn_protocol == "h2"
            ssl.close rescue nil
            return nil
          end
          ssl
        else
          Proxy::Upstream.dial(host, port, connect_timeout: ct, io_timeout: it, overrides: overrides) # h2c prior-knowledge
        end
      end

      private def self.write_request(io : IO, headers : Array({String, String}), body : Bytes?,
                                     flow : SendFlow) : Nil
        io.write(Frame::PREFACE)
        # SETTINGS_ENABLE_PUSH=0 (id 0x2): a one-shot repeater never wants server push, and
        # pushed DATA on a non-1 stream would consume the connection flow-control window
        # without being credited back (the DATA loop only credits stream 1), stalling a
        # large response. Disabling push at the source avoids the whole class.
        no_push = Bytes[0x00_u8, 0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
        io.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, no_push).to_bytes)
        block = HPACK::Encoder.new.encode(headers)
        write_header_block(io, block, body.nil? || body.empty?)
        io.flush
        return if body.nil? || body.empty?
        await_settings(io, flow)
        write_data(io, body, flow)
        io.flush
      end

      # Read the peer's SETTINGS before the FIRST DATA frame.
      #
      # RFC 9113 §3.4 makes SETTINGS the first frame a server sends, and §6.9.2 lets its
      # SETTINGS_INITIAL_WINDOW_SIZE put the stream window BELOW the 65535 default. Writing
      # DATA before reading it is how a 20 KB body went out against an advertised 16384-byte
      # window — the request was already over the limit before the first WINDOW_UPDATE could
      # have mattered, so no amount of blocking later would have helped.
      #
      # Exactly ONE frame, and every failure is tolerated: a peer that opens with something
      # else has told us it will not send SETTINGS first, and a peer that sends nothing at all
      # costs one idle timeout that the response read was going to spend anyway. Neither is a
      # reason to fail a send — the RFC defaults still apply.
      private def self.await_settings(io : IO, flow : SendFlow) : Nil
        pump_once(io, flow) unless flow.settings_seen?
      end

      # Read and dispatch ONE frame from the peer while the request is still being written.
      # SETTINGS/PING/WINDOW_UPDATE are handled here (they are the write loop's business);
      # everything else is stashed for `read_response`, which drains `pending` before it
      # touches the socket. Returns false once the socket goes quiet.
      private def self.pump_once(io : IO, flow : SendFlow) : Bool
        frame = begin
          Frame.read(io)
        rescue IO::TimeoutError
          return false # idle, not dead — the caller decides whether that is fatal
        rescue IO::Error
          flow.eof = true
          return false
        end
        if frame.nil?
          flow.eof = true
          return false
        end
        flow.frames += 1
        return false if flow.frames > MAX_FRAMES
        case frame.frame_type
        when Frame::Type::Settings
          unless frame.ack?
            apply_settings(frame, flow)
            flow.settings_seen = true
            ack(io, Frame::Type::Settings, Bytes.empty)
          end
        when Frame::Type::Ping
          ack(io, Frame::Type::Ping, frame.payload) unless frame.ack?
        when Frame::Type::WindowUpdate
          credit(frame, flow)
        when Frame::Type::Goaway
          flow.goaway = goaway_reason(frame)
          flow.closed = true
          flow.pending << frame
        when Frame::Type::RstStream
          if frame.stream_id == 1
            flow.rst = rst_reason(frame)
            flow.closed = true
          end
          flow.pending << frame
        else
          # The peer answered before we finished the body (a 413/431 rejection, say). The
          # stream is over: stop writing at it and go read what it said.
          flow.closed = true if frame.stream_id == 1 && frame.end_stream? && frame.end_headers?
          flow.pending << frame
        end
        true
      end

      # Apply a peer SETTINGS frame's SETTINGS_INITIAL_WINDOW_SIZE (id 0x4) to the send-side
      # stream window. §6.9.2: the new value is a DELTA against the previous initial size
      # applied to every open stream, not an assignment — space already consumed stays
      # consumed, and the window may end up negative.
      private def self.apply_settings(frame : Frame::Header, flow : SendFlow) : Nil
        payload = frame.payload
        i = 0
        while i + 6 <= payload.size
          id = IO::ByteFormat::BigEndian.decode(UInt16, payload[i, 2])
          value = IO::ByteFormat::BigEndian.decode(UInt32, payload[i + 2, 4]).to_i64
          if id == 0x4_u16
            flow.stream += value - flow.initial
            flow.initial = value
          end
          i += 6
        end
      end

      # Credit an inbound WINDOW_UPDATE to the connection (stream 0) or our stream (1). The
      # read loop dispatched this frame type only to DISCARD it, which is why the send window
      # could never reopen.
      private def self.credit(frame : Frame::Header, flow : SendFlow) : Nil
        return if frame.payload.size < 4
        inc = (IO::ByteFormat::BigEndian.decode(UInt32, frame.payload[0, 4]) & 0x7fffffff_u32).to_i64
        case frame.stream_id
        when 0_u32 then flow.conn += inc
        when 1_u32 then flow.stream += inc
        end
      end

      # HEADERS, then CONTINUATION for every 16 KiB after the first.
      #
      # The old code wrote the whole block as one frame, on the belief that `MAX_FRAME` was a
      # DATA-only concern (`write_data` was its only reader). RFC 9113 §4.2 caps EVERY frame at
      # the peer's SETTINGS_MAX_FRAME_SIZE, so a 30 KB header value went out as a 22530-byte
      # HEADERS and any origin that enforces the default answered GOAWAY(FRAME_SIZE_ERROR) —
      # making a header-size probe, an HPACK test, and any request with a large cookie jar or
      # JWT unsendable over h2.
      #
      # Splitting at `MAX_FRAME` needs no round trip to learn the peer's setting: §6.5.2 fixes
      # the initial value at 2^14 and forbids a smaller one, so 16384 is legal against every
      # peer, and gori writes the block before the peer's SETTINGS has even arrived. END_STREAM
      # belongs on the HEADERS frame, END_HEADERS on the last CONTINUATION (§6.10).
      private def self.write_header_block(io : IO, block : Bytes, end_stream : Bool) : Nil
        head = Math.min(MAX_FRAME, block.size)
        flags = (head >= block.size ? Frame::END_HEADERS : 0_u8) | (end_stream ? Frame::END_STREAM : 0_u8)
        io.write(Frame::Header.new(Frame::Type::Headers.value, flags, 1_u32, block[0, head]).to_bytes)
        offset = head
        while offset < block.size
          n = Math.min(MAX_FRAME, block.size - offset)
          cont = offset + n >= block.size ? Frame::END_HEADERS : 0_u8
          io.write(Frame::Header.new(Frame::Type::Continuation.value, cont, 1_u32, block[offset, n]).to_bytes)
          offset += n
        end
      end

      # The request body as DATA frames, never exceeding the peer's send window (§6.9.1).
      # When the window is exhausted the writer blocks reading frames until a WINDOW_UPDATE
      # reopens it; the bound is the socket's own idle timeout, after which the stall is
      # reported for what it is rather than left to the origin's GOAWAY.
      private def self.write_data(io : IO, body : Bytes, flow : SendFlow) : Nil
        offset = 0
        while offset < body.size
          while flow.available <= 0 && !flow.closed?
            io.flush # the peer cannot grant window for frames still sitting in our buffer
            break unless pump_once(io, flow)
          end
          break if flow.closed?
          raise Gori::Error.new(flow_stalled(offset, body.size, flow)) if flow.available <= 0
          n = Math.min(Math.min(MAX_FRAME.to_i64, (body.size - offset).to_i64), flow.available).to_i
          last = offset + n >= body.size
          flags = last ? Frame::END_STREAM : 0_u8
          io.write(Frame::Header.new(Frame::Type::Data.value, flags, 1_u32, body[offset, n]).to_bytes)
          flow.conn -= n
          flow.stream -= n
          offset += n
        end
      end

      # Why the body could not be finished. Names the flow-control window — gori's own
      # accounting — rather than blaming the origin for a refusal it never made, and says
      # plainly that the request did NOT go out whole, so no status is read as a verdict on
      # the payload the operator meant to send.
      private def self.flow_stalled(sent : Int32, total : Int32, flow : SendFlow) : String
        base = "h2 flow control: only #{sent} of #{total} request body bytes could be sent"
        if flow.eof?
          "#{base} — the origin closed the connection before granting window for the rest " \
          "(RFC 9113 §6.9). The request was NOT fully sent."
        else
          "#{base} — the origin never granted flow-control window for the rest (RFC 9113 §6.9): " \
          "its connection window is #{flow.conn} and its stream window #{flow.stream}. " \
          "The request was NOT fully sent."
        end
      end

      # Reads frames until stream 1 closes. `clean_eos` is true only when the stream ended on
      # a real END_STREAM — false when it was cut by GOAWAY/RST_STREAM, a mid-stream
      # connection drop, or a MAX_BODY truncation, so the caller can flag the response as
      # incomplete (mirrors the h1 engine's premature-EOF signal). `goaway`/`rst` are the
      # origin's own stated reasons, when it gave one.
      #
      # Starts by draining `flow.pending` — the frames the WRITE side had to read off the
      # socket while waiting for flow-control window. They arrived before anything read here
      # and must be processed in that order.
      private def self.read_response(io : IO, flow : SendFlow) : Reply
        decoder = HPACK::Decoder.new
        header_buf = IO::Memory.new
        body = IO::Memory.new
        headers = [] of {String, String}
        status = 0
        done = false
        clean_eos = false    # a genuine END_STREAM closed the stream
        goaway = flow.goaway # the origin's stated reason for hanging up
        rst = flow.rst       # the origin's stated reason for killing the stream
        trailers = nil.as(Array(String)?)
        final_seen = false         # the final (non-interim) response header block is absorbed
        end_stream_pending = false # END_STREAM seen on a HEADERS frame whose block isn't closed yet
        timed_out = false          # the read ended on an idle timeout, not on a closed socket
        pending = flow.pending
        at = 0

        until done
          if at < pending.size
            frame = pending[at]
            at += 1
          else
            # An IO error mid-response (connection reset — e.g. an origin that closed
            # right after a non-END_STREAM DATA) is end-of-data, not a hard failure:
            # treat it like a clean EOF and return what arrived, flagged incomplete
            # (mirrors the h1 engine). A Gori::Error from Frame.read (oversized/corrupt
            # frame — a real protocol violation) is NOT swallowed: it propagates to the
            # outer rescue and surfaces as a failed repeater, since the workbench exists to
            # reveal exactly that. An idle TIMEOUT is separated from a closed socket: "the
            # origin sent nothing" and "the origin hung up" are different findings and only
            # one of them is worth retrying.
            frame = begin
              Frame.read(io)
            rescue IO::TimeoutError
              timed_out = true
              nil
            rescue IO::Error
              nil
            end
            break if frame.nil?
            # Count EVERY frame, not just data/headers: an origin flooding PING/PRIORITY/
            # WINDOW_UPDATE without ever sending END_STREAM trips no byte cap and no idle
            # timeout, so this ceiling is what guarantees the loop terminates. On trip the
            # stream is left un-closed → the response is flagged incomplete.
            flow.frames += 1
            break if flow.frames > MAX_FRAMES
          end
          case frame.frame_type
          when Frame::Type::Settings
            ack(io, Frame::Type::Settings, Bytes.empty) unless frame.ack?
          when Frame::Type::Ping
            ack(io, Frame::Type::Ping, frame.payload) unless frame.ack?
          when Frame::Type::Goaway
            goaway = goaway_reason(frame)
            done = true
          when Frame::Type::RstStream
            if frame.stream_id == 1
              # The 4-byte error code used to be read only as "stop looping", so
              # REFUSED_STREAM, CANCEL and ENHANCE_YOUR_CALM were indistinguishable from a
              # dead socket — see `no_response`.
              rst = rst_reason(frame)
              done = true
            end
          when Frame::Type::Headers
            next unless frame.stream_id == 1
            chunk = header_block(frame)
            break if header_buf.bytesize + chunk.size > MAX_HEADER_BLOCK # flood — abort
            header_buf.write(chunk)
            # END_STREAM only completes the stream once the header block is fully
            # absorbed — a HEADERS with END_STREAM but not END_HEADERS is continued
            # by CONTINUATION frames; finishing early would drop them (and decode no
            # status). Defer completion until END_HEADERS.
            end_stream_pending = frame.end_stream?
            if frame.end_headers?
              status, names = absorb(header_buf, decoder, headers, status)
              trailers = note_trailers(trailers, names, final_seen)
              final_seen ||= !interim?(status)
              done = clean_eos = true if end_stream_pending
              headers.clear if !end_stream_pending && interim?(status)
            end
          when Frame::Type::Continuation
            next unless frame.stream_id == 1
            break if header_buf.bytesize + frame.payload.size > MAX_HEADER_BLOCK # flood — abort
            header_buf.write(frame.payload)
            if frame.end_headers?
              status, names = absorb(header_buf, decoder, headers, status)
              trailers = note_trailers(trailers, names, final_seen)
              final_seen ||= !interim?(status)
              done = clean_eos = true if end_stream_pending
              headers.clear if !end_stream_pending && interim?(status)
            end
          when Frame::Type::Data
            next unless frame.stream_id == 1
            consumed = frame.payload.size # flow control counts the WHOLE DATA payload (incl. padding)
            body.write(data_block(frame)) if body.bytesize < MAX_BODY
            done = clean_eos = true if frame.end_stream?
            break if body.bytesize >= MAX_BODY # over-large/streaming body — truncate
            # Replenish the connection (stream 0) AND stream flow-control windows by
            # what we just consumed, so the origin keeps sending past the 65535-byte
            # default window. Without this, any response body > 64 KiB stalls until
            # the IO timeout (no WINDOW_UPDATE was ever sent).
            if !done && consumed > 0
              window_update(io, 0_u32, consumed)
              window_update(io, 1_u32, consumed)
            end
          else
            # WINDOW_UPDATE / PUSH_PROMISE / PRIORITY — ignored for a one-shot
          end
        end

        Reply.new(status, headers, body.size == 0 ? nil : body.to_slice, clean_eos,
          goaway, rst, trailers, timed_out)
      end

      # Names decoded from a header block that arrived AFTER the final response block are
      # TRAILERS. `Assembler` records exactly this for a captured h2 flow; the repeater built
      # its own head and lost it, so a gRPC "Trailers-Only" response (grpc-status in the
      # initial HEADERS) and a real trailers response rendered byte-identically — and whether
      # a gateway/CDN/WAF/service-mesh promotes a trailer into a header, or collapses a real
      # trailers response into Trailers-Only, is a first-class gRPC test.
      private def self.note_trailers(trailers : Array(String)?, names : Array(String),
                                     final_seen : Bool) : Array(String)?
        return trailers if !final_seen || names.empty?
        (trailers ||= [] of String).concat(names)
        trailers
      end

      # RFC 9113 §7 error codes, by their spec names — the operator is going to search for
      # the name, not the integer. Shared by GOAWAY (§6.8) and RST_STREAM (§7): the code
      # space is one registry.
      ERROR_CODES = {
        0 => "NO_ERROR", 1 => "PROTOCOL_ERROR", 2 => "INTERNAL_ERROR", 3 => "FLOW_CONTROL_ERROR",
        4 => "SETTINGS_TIMEOUT", 5 => "STREAM_CLOSED", 6 => "FRAME_SIZE_ERROR", 7 => "REFUSED_STREAM",
        8 => "CANCEL", 9 => "COMPRESSION_ERROR", 10 => "CONNECT_ERROR", 11 => "ENHANCE_YOUR_CALM",
        12 => "INADEQUATE_SECURITY", 13 => "HTTP_1_1_REQUIRED",
      }

      # A GOAWAY payload as a sentence (§6.8: last-stream-id, error code, optional debug data).
      # The code was previously read only as "stop looping", so an origin that told gori
      # exactly what it disliked about gori's own frames — FRAME_SIZE_ERROR, COMPRESSION_ERROR,
      # ENHANCE_YOUR_CALM — was reported as "no h2 response", pointing at the network.
      private def self.goaway_reason(frame : Frame::Header) : String
        payload = frame.payload
        return "h2 GOAWAY (no error code)" if payload.size < 8
        code = IO::ByteFormat::BigEndian.decode(UInt32, payload[4, 4]).to_i
        name = ERROR_CODES[code]? || "error code #{code}"
        debug = payload.size > 8 ? String.new(payload[8..]).scrub.strip : ""
        debug.empty? ? "h2 GOAWAY #{name}" : "h2 GOAWAY #{name} (#{debug})"
      end

      # A RST_STREAM payload as a sentence (§6.4: a single 4-octet error code). The sibling
      # of `goaway_reason`, one `case` arm away and written for the same reason: the code
      # names WHY the stream died, and REFUSED_STREAM (§8.7) is not a failure at all but an
      # instruction to retry on a new connection.
      private def self.rst_reason(frame : Frame::Header) : String
        payload = frame.payload
        return "h2 RST_STREAM on stream #{frame.stream_id} (no error code)" if payload.size < 4
        code = IO::ByteFormat::BigEndian.decode(UInt32, payload[0, 4]).to_i
        name = ERROR_CODES[code]? || "error code #{code}"
        "h2 RST_STREAM #{name} on stream #{frame.stream_id}"
      end

      # Decode a completed header block, splitting :status from regular headers. Returns the
      # status and the REGULAR field names this block contributed, so the caller can tell a
      # trailing block's fields from the response head's (see `note_trailers`).
      private def self.absorb(buf : IO::Memory, decoder : HPACK::Decoder,
                              headers : Array({String, String}), status : Int32) : {Int32, Array(String)}
        names = [] of String
        decoder.decode(buf.to_slice).each do |(name, value)|
          if name == ":status"
            status = value.to_i? || status
          elsif !name.starts_with?(':')
            headers << {name, value}
            names << name
          end
        end
        buf.clear
        {status, names}
      end

      # An interim (informational) response: its header fields precede — and are not part
      # of — the final response (RFC 9110 §15.2), so they're dropped, not merged.
      private def self.interim?(status : Int32) : Bool
        100 <= status < 200
      end

      private def self.ack(io : IO, type : Frame::Type, payload : Bytes) : Nil
        io.write(Frame::Header.new(type.value, Frame::ACK, 0_u32, payload).to_bytes)
        io.flush
      end

      # WINDOW_UPDATE crediting `increment` bytes back to `stream_id` (0 = connection-
      # level). The reserved high bit stays clear (increment is a small frame size).
      private def self.window_update(io : IO, stream_id : UInt32, increment : Int32) : Nil
        return if increment <= 0
        payload = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(increment.to_u32, payload)
        io.write(Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, stream_id, payload).to_bytes)
        io.flush
      rescue
        # The origin may have already closed (e.g. a truncated response) — crediting a
        # window we no longer need is moot; the next Frame.read sees the EOF and ends
        # the loop. Don't let a dead-socket write fail an otherwise-usable response.
      end

      # The h1-form head text an operator typed, as the h2 fields that go on the wire.
      #
      # gori has TWO h2 request encoders and they used to disagree. The proxy's intercept-edit
      # path (`HeadCodec.parse_request` → `append_regular`) forwards `transfer-engineering`-class
      # connection headers, trailing-space values and duplicates; this one — which EVERY scripted
      # surface uses (repeater, fuzz, miner, active probe, discover, MCP) — dropped them. So the
      # h2.TE / h2.CL downgrade desync, the single most important h2 test there is, was
      # expressible only by hand-editing a live intercepted request in the TUI, and gori reported
      # the resulting `200` as though the header had been sent.
      #
      # This side now converges on the capable one: `HeadCodec.request_line` and
      # `HeadCodec.header_lines` ARE the rules, and the field list is passed through. What is
      # left is only what h2 has no representation for at all (`reject_uncarriable`), and that
      # refuses loudly.
      #
      # `preserve_field_case` is the one remaining normalization, and it is opt-out rather than
      # gone because the h1 text is BOTH a wire format and the paste buffer: a request copied
      # from Burp or curl is conventionally title-cased, and h2 requires lowercase (§8.2.1), so
      # sending `Content-Type` verbatim would RST the stream of every ordinary send. A surface
      # turns it on where the operator has said the bytes ARE the message (`--verbatim`, MCP
      # `verbatim:true`), because then an uppercase name is the conformance probe.
      def self.parse_request(request : Bytes, scheme : String, host : String,
                             port : Int32, preserve_field_case : Bool = false) : {Array({String, String}), Bytes?}
        head_bytes, body = split_head_body(request)
        lines = String.new(head_bytes).split('\n').map(&.rstrip('\r'))
        line = lines[0]? || "GET / HTTP/2"
        parsed_method, parsed_path = HeadCodec.request_line(line)
        # No space at all is not a request line; keep the whole token as the method rather
        # than inventing one, which is what a `:method` probe (`GET\r\n…`) would want to see.
        method = parsed_method || line
        path = parsed_path || "/"

        # An explicit `Host:` header maps to `:authority` (RFC 9113 §8.3.1 — h2 has no
        # Host field). Honor its value so editing the request's host (a vhost /
        # host-header-confusion probe, in the TUI editor, MCP `headers`, or `gori run
        # repeater -H "Host: …"`) actually reaches the wire — matching the h1 engine, which
        # sends the edited Host verbatim. Without this the edited Host was silently
        # dropped and `:authority` always came from the dialed target. The connection
        # target is unchanged: you still connect to `host`, but can CLAIM a different
        # authority. Falls back to the dialed host when no Host line is present.
        #
        # The FIRST `Host:` becomes `:authority`; every SUBSEQUENT one is carried as a
        # regular `host` field. `authority_override` used to be a single slot each line
        # overwrote, so `Host: first` + `Host: second` went out as one `:authority: second`
        # and the first vanished with no notice — a duplicate `Host:` is a standard
        # host-header-confusion / cache-poisoning / h2-downgrade-desync probe, and h1 puts
        # both lines on the wire for the identical bytes. Carrying rather than refusing is
        # deliberate: the TUI Repeater has no field-native escape hatch, so a refusal would
        # strand that surface, and `:authority` alongside an explicit `host` is legal to emit
        # (it is the very shape `HeadCodec.resolve_authority` preserves in the other
        # direction) — and it is what a host-confusion probe wants on the wire.
        authority_override = nil
        regular = [] of {String, String}
        lines[1..]?.try &.each do |field_line|
          next if field_line.empty?
          pair = HeadCodec.header_field(field_line)
          raise Gori::Error.new(unencodable_line(field_line)) unless pair
          raw_name, value = pair
          if raw_name.compare("host", case_insensitive: true) == 0 && authority_override.nil?
            # An EMPTY `Host:` maps to an empty `:authority`, not to the dial target: the
            # operator asked for a request with no authority (the missing-authority probe),
            # and quietly substituting gori's own connection target answered a question they
            # did not ask.
            authority_override = value
            next
          end
          regular << {preserve_field_case ? raw_name : raw_name.downcase, value}
        end

        headers = [{":method", method}, {":path", path}, {":scheme", scheme},
                   {":authority", authority_override || authority(host, port, scheme)}]
        headers.concat(regular)
        headers.each { |(n, v)| reject_uncarriable(n, v) }
        {headers, body}
      end

      # Why a head line has no h2 form.
      #
      # A non-empty line that is not a header field means this text has no faithful h2 form,
      # and skipping it SILENTLY sent a different request than the operator wrote. It is what
      # a payload carrying a bare LF produces: `x-fuzz: be\naf` splits here, the `af` tail lands
      # on a line with no colon, and the field went out as `x-fuzz: be` while the Fuzzer
      # labelled the result row with the whole `be\naf` payload — a status measured against a
      # request gori never sent. h1 carries those bytes verbatim (P7, malformed input IS the
      # payload); h2 has no encoding for them, so the honest answer is to refuse and say so,
      # exactly as `HeadCodec.h1_faithful?` refuses the same shape on the rewrite path. A CRLF
      # that yields two WELL-FORMED fields is left alone deliberately: that is indistinguishable
      # from the operator typing two headers, and h1 puts two headers on the wire for it too.
      #
      # Two shapes get here and they need different sentences. The old message blamed a CR, LF
      # or NUL for both — so an operator who typed `:scheme: http` (`colon == 0`, a pseudo-header
      # this encoder derives rather than reads) was sent hunting for an invisible control byte
      # in a line that had none.
      private def self.unencodable_line(line : String) : String
        if line.starts_with?(':')
          "cannot send over h2: #{line.inspect} looks like a pseudo-header. gori derives " \
          ":method, :path, :scheme and :authority from the request line and the dialed target " \
          "— they cannot be set from the head text."
        else
          "cannot send over h2: #{line.inspect} is not a header field. A bare CR or LF inside " \
          "a header value splits it into a line with no name, which has no HTTP/2 representation " \
          "(RFC 9113 §8.2.1) — h1 carries those bytes verbatim, h2 cannot."
        end
      end

      # The h1-text projection of the fields this engine WILL encode — the same projection
      # `Proxy::H2::Assembler` stores for a captured h2 flow, so a repeater send and a proxied
      # request render identically in History.
      #
      # It exists because every report of "the request actually put on the wire" was derived
      # from the operator's TEXT, which on the h2 path is only an input: the encoder resolves
      # `:path` from the request line, folds `Host:` into `:authority` and lowercases names.
      # MCP's `effective_request` therefore described a request to `/mcp-noversion` carrying
      # `Transfer-Encoding` when `GET /` had gone out, and `run show --format raw` printed the
      # same bytes back. Lossy in the way the capture projection is documented to be lossy
      # (`:scheme` and a duplicate pseudo-header have nowhere to go, `head_codec.cr:24-32`),
      # but it is the fields, not the source text.
      def self.encoded_request(request : Bytes, *, scheme : String, host : String, port : Int32,
                               preserve_field_case : Bool = false) : Bytes
        fields, body = parse_request(request, scheme, host, port, preserve_field_case)
        head = HeadCodec.synth_request(fields, HeadCodec.pseudo(fields, ":authority") || "")
        return head unless body && !body.empty?
        joined = Bytes.new(head.size + body.size)
        head.copy_to(joined)
        body.copy_to(joined + head.size)
        joined
      end

      # The FAITHFUL text view of a field-native request — every field in the order it will be
      # encoded, PSEUDO-HEADERS INCLUDED, so a duplicate `:method`, a `:scheme` that disagrees
      # with the connection, `:protocol`, an unknown pseudo and a leading-space value all SHOW.
      #
      # This is where "report before capability" is paid: `synth_request`/`encoded_request`
      # project the fields onto an h1 head, and that projection is the very thing a field-native
      # request defeats — `:scheme` and every duplicate pseudo vanish (F11), so a new shape
      # would land INVISIBLE in `run show` and MCP `effective_request` (the F5 failure again).
      # The pseudo-explicit dump is the same "raw frames are the truth, the projection is a
      # view" split `Assembler` draws (P7): a RICHER view for the surfaces that report the wire,
      # never a wire format itself — the wire is the HPACK block `write_request` encodes from
      # the identical array. It is deliberately NOT a valid HTTP/1.1 head (a duplicate `:method`
      # has no request line that could hold it); a consumer that needs method/target reads them
      # off the fields with `pseudo_field`, not by parsing this text.
      def self.field_dump(fields : Array({String, String}), body : Bytes?) : Bytes
        head = String.build do |io|
          fields.each { |(n, v)| io << n << ": " << v << "\r\n" }
          io << "\r\n"
        end.to_slice
        return head unless body && !body.empty?
        joined = Bytes.new(head.size + body.size)
        head.copy_to(joined)
        body.copy_to(joined + head.size)
        joined
      end

      # The FIRST value of a pseudo-header (`:method`, `:path`, …) in a field list, or nil.
      # A field-native request may carry the pseudo more than once (that IS a probe); the
      # scope gate and the History columns anchor on the first, the same one a conformant
      # receiver would act on.
      def self.pseudo_field(fields : Array({String, String}), name : String) : String?
        HeadCodec.pseudo(fields, name)
      end

      # A synthetic `METHOD PATH HTTP/2` head for the SCOPE / extract path only. The Sandbox
      # gate and the binding-extract subject key off a request line (`Outbound.request_target`
      # reads the path token), and a field-native send has no head text — so one is derived
      # from the first `:method`/`:path`, the fields a conformant receiver routes on. Never put
      # on the wire; the HPACK block is.
      def self.field_scope_line(fields : Array({String, String})) : Bytes
        method = pseudo_field(fields, ":method") || "GET"
        path = pseudo_field(fields, ":path") || "/"
        "#{method} #{path} HTTP/2\r\n\r\n".to_slice
      end

      # RFC 9113 §8.2.1: a field name or value may carry no CR, LF or NUL. `rstrip('\r')`
      # above only removes a TRAILING CR, so a lone CR mid-value survived the split and went
      # out raw, and a NUL was never looked at — both producing a field a conformant peer must
      # treat as malformed, with no notice to the operator and the Fuzzer still labelling the
      # row with the payload it believed it sent. Refusing here keeps the h1/h2 divergence
      # visible instead of silent; the h1 engine is unchanged and still sends them byte-exact.
      private def self.reject_uncarriable(name : String, value : String) : Nil
        {name, value}.each do |s|
          next unless s.each_char.any? { |c| c == '\r' || c == '\n' || c == '\0' }
          raise Gori::Error.new(
            "cannot send over h2: #{name.inspect} carries a CR, LF or NUL, which has no " \
            "HTTP/2 representation (RFC 9113 §8.2.1) — h1 sends those bytes verbatim, h2 cannot.")
        end
      end

      private def self.authority(host : String, port : Int32, scheme : String) : String
        default = scheme == "https" ? 443 : 80
        # An IPv6 literal host must be bracketed in the :authority pseudo-header, else the
        # colons collide with the port separator and a strict server rejects the stream
        # (mirrors FlowRequest.build_target's h1 bracketing).
        h = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]" : host
        port == default ? h : "#{h}:#{port}"
      end

      # Split at the first CRLFCRLF (head/body boundary); the editor always joins
      # lines with CRLF, so the blank line is exact.
      private def self.split_head_body(bytes : Bytes) : {Bytes, Bytes?}
        i = 0
        while i + 3 < bytes.size
          if bytes[i] == 0x0d && bytes[i + 1] == 0x0a && bytes[i + 2] == 0x0d && bytes[i + 3] == 0x0a
            body = i + 4 < bytes.size ? bytes[(i + 4)..] : nil
            return {bytes[0...i], body}
          end
          i += 1
        end
        {bytes, nil}
      end

      private def self.header_block(frame : Frame::Header) : Bytes
        payload = frame.payload
        offset = 0
        pad = 0
        if frame.padded?
          return Bytes.empty if payload.empty?
          pad = payload[0].to_i
          offset = 1
        end
        offset += 5 if frame.priority?
        finish = payload.size - pad
        finish <= offset ? Bytes.empty : payload[offset...finish]
      end

      private def self.data_block(frame : Frame::Header) : Bytes
        return frame.payload unless frame.padded?
        return Bytes.empty if frame.payload.empty?
        pad = frame.payload[0].to_i
        finish = frame.payload.size - pad
        finish <= 1 ? Bytes.empty : frame.payload[1...finish]
      end

      # The response head, through the SAME projection the capture path uses.
      #
      # This used to be a local `String.build` that concatenated the final and the trailing
      # header blocks with no record of which arrived where — so `HeadCodec`'s
      # `X-Gori-Trailers` marker, which `Assembler` has emitted on every captured h2 flow,
      # never reached the Repeater. Reusing `synth_response` is the point of `HeadCodec`
      # existing: the repeater projection and the capture projection now cannot drift, and
      # the CR/LF escaping that used to live here as `visualize_field` is `line_safe`'s job,
      # which additionally disambiguates a literal backslash from an injected one.
      private def self.synth_head(reply : Reply) : Bytes
        fields = [{":status", reply.status.to_s}]
        fields.concat(reply.headers)
        HeadCodec.synth_response(fields, reply.trailers)
      end

      private def self.failure(message : String, started : Time::Instant) : Result
        Result.new(Bytes.new(0), nil, nil, elapsed(started), message)
      end

      # A nil socket here means no usable HTTP/2 connection — could be unreachable,
      # an origin that doesn't offer h2 over ALPN, or (for verified https) a cert that
      # failed verification. Spell that out instead of a bare "connect failed".
      #
      # The two conditions are SEPARATE. The guard used to be `scheme == "https" && verify`,
      # so `-k` / MCP `insecure:true` / `gori mcp --insecure-upstream` routed an **https**
      # target into the h2c `else` and reported a cleartext prior-knowledge diagnosis for a
      # failed ALPN negotiation — sending the operator after a problem that does not exist,
      # on the branch they hit most (`-k` is the normal mode against a lab origin). The
      # transport decides the ALPN wording; verification only adds a clause.
      private def self.connect_error(scheme : String, host : String, port : Int32, verify : Bool) : String
        base = "h2 connect failed (no h2 negotiated): #{host}:#{port}"
        return "#{base} — host unreachable or the origin doesn't offer HTTP/2 (h2c) here" unless scheme == "https"
        cert = verify ? ", or its TLS certificate failed verification" : ""
        "#{base} — host unreachable, the origin doesn't offer HTTP/2 via ALPN#{cert}"
      end

      private def self.elapsed(started : Time::Instant) : Int64
        (Time.instant - started).total_microseconds.to_i64
      end
    end
  end
end
