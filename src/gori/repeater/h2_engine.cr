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
    # PING answered. The RESPONSE side is flow-controlled — each DATA frame is
    # credited straight back with a WINDOW_UPDATE on the connection + stream, so
    # responses past the 65535-byte default window stream fine. The REQUEST side is
    # not flow-controlled (a >64 KiB request body could stall — fine for the
    # workbench; repeater bodies are typically small).
    module H2Engine
      MAX_FRAME = 16384
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
          write_request(upstream, headers, body)
          status, resp_headers, resp_body, complete, goaway = read_response(upstream)
          if status == 0 && resp_headers.empty?
            # A GOAWAY is the origin naming the reason it hung up (RFC 9113 §6.8) and it is
            # usually about the bytes GORI sent — reporting it as "no h2 response" sent the
            # operator looking at the origin. Prefer it over the generic sentence.
            return failure(goaway ? "#{goaway} from #{host}:#{port}" : "no h2 response from #{host}:#{port}", started)
          end
          head = synth_head(status, resp_headers)
          resp = Proxy::Codec::Http1.parse_response_head(head)
          Result.new(head, resp_body, resp, elapsed(started), incomplete: !complete)
        rescue ex
          failure(ex.message || "h2 repeater error", started)
        ensure
          upstream.close rescue nil
        end
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

      private def self.write_request(io : IO, headers : Array({String, String}), body : Bytes?) : Nil
        io.write(Frame::PREFACE)
        # SETTINGS_ENABLE_PUSH=0 (id 0x2): a one-shot repeater never wants server push, and
        # pushed DATA on a non-1 stream would consume the connection flow-control window
        # without being credited back (the DATA loop only credits stream 1), stalling a
        # large response. Disabling push at the source avoids the whole class.
        no_push = Bytes[0x00_u8, 0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
        io.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, no_push).to_bytes)
        block = HPACK::Encoder.new.encode(headers)
        write_header_block(io, block, body.nil? || body.empty?)
        write_data(io, body) if body && !body.empty?
        io.flush
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

      private def self.write_data(io : IO, body : Bytes) : Nil
        offset = 0
        while offset < body.size
          n = Math.min(MAX_FRAME, body.size - offset)
          last = offset + n >= body.size
          flags = last ? Frame::END_STREAM : 0_u8
          io.write(Frame::Header.new(Frame::Type::Data.value, flags, 1_u32, body[offset, n]).to_bytes)
          offset += n
        end
      end

      # Reads frames until stream 1 closes; returns {status, headers, body,
      # clean_eos, goaway}. clean_eos is true only when the stream ended on a real
      # END_STREAM — false when it was cut by GOAWAY/RST_STREAM, a mid-stream
      # connection drop, or a MAX_BODY truncation, so the caller can flag the
      # response as incomplete (mirrors the h1 engine's premature-EOF signal).
      # `goaway` is the origin's stated reason for hanging up, when it gave one.
      private def self.read_response(io : IO) : {Int32, Array({String, String}), Bytes?, Bool, String?}
        decoder = HPACK::Decoder.new
        header_buf = IO::Memory.new
        body = IO::Memory.new
        headers = [] of {String, String}
        status = 0
        done = false
        clean_eos = false          # a genuine END_STREAM closed the stream
        goaway = nil.as(String?)   # the origin's stated reason for hanging up
        end_stream_pending = false # END_STREAM seen on a HEADERS frame whose block isn't closed yet
        frames = 0                 # every frame counted (incl. ping/priority) — bounds a junk-frame flood

        until done
          # An IO error mid-response (connection reset — e.g. an origin that closed
          # right after a non-END_STREAM DATA) is end-of-data, not a hard failure:
          # treat it like a clean EOF and return what arrived, flagged incomplete
          # (mirrors the h1 engine). A Gori::Error from Frame.read (oversized/corrupt
          # frame — a real protocol violation) is NOT swallowed: it propagates to the
          # outer rescue and surfaces as a failed repeater, since the workbench exists to
          # reveal exactly that.
          frame = begin
            Frame.read(io)
          rescue IO::Error
            nil
          end
          break if frame.nil?
          # Count EVERY frame, not just data/headers: an origin flooding PING/PRIORITY/
          # WINDOW_UPDATE without ever sending END_STREAM trips no byte cap and no idle
          # timeout, so this ceiling is what guarantees the loop terminates. On trip the
          # stream is left un-closed → the response is flagged incomplete.
          frames += 1
          break if frames > MAX_FRAMES
          case frame.frame_type
          when Frame::Type::Settings
            ack(io, Frame::Type::Settings, Bytes.empty) unless frame.ack?
          when Frame::Type::Ping
            ack(io, Frame::Type::Ping, frame.payload) unless frame.ack?
          when Frame::Type::Goaway
            goaway = goaway_reason(frame)
            done = true
          when Frame::Type::RstStream
            done = true if frame.stream_id == 1
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
              status = absorb(header_buf, decoder, headers, status)
              done = clean_eos = true if end_stream_pending
              headers.clear if !end_stream_pending && interim?(status)
            end
          when Frame::Type::Continuation
            next unless frame.stream_id == 1
            break if header_buf.bytesize + frame.payload.size > MAX_HEADER_BLOCK # flood — abort
            header_buf.write(frame.payload)
            if frame.end_headers?
              status = absorb(header_buf, decoder, headers, status)
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

        {status, headers, body.size == 0 ? nil : body.to_slice, clean_eos, goaway}
      end

      # RFC 9113 §7 error codes, by their spec names — the operator is going to search for
      # the name, not the integer.
      GOAWAY_ERRORS = {
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
        name = GOAWAY_ERRORS[code]? || "error code #{code}"
        debug = payload.size > 8 ? String.new(payload[8..]).scrub.strip : ""
        debug.empty? ? "h2 GOAWAY #{name}" : "h2 GOAWAY #{name} (#{debug})"
      end

      # Decode a completed header block, splitting :status from regular headers.
      private def self.absorb(buf : IO::Memory, decoder : HPACK::Decoder,
                              headers : Array({String, String}), status : Int32) : Int32
        decoder.decode(buf.to_slice).each do |(name, value)|
          if name == ":status"
            status = value.to_i? || status
          elsif !name.starts_with?(':')
            headers << {visualize_field(name), visualize_field(value)}
          end
        end
        buf.clear
        status
      end

      # An interim (informational) response: its header fields precede — and are not part
      # of — the final response (RFC 9110 §15.2), so they're dropped, not merged.
      private def self.interim?(status : Int32) : Bool
        100 <= status < 200
      end

      # RFC 9113 §8.2.1 forbids CR/LF in an h2 field name/value. If a non-compliant origin
      # smuggles one in, ESCAPE it (don't drop the header) so it can't fold into a phantom
      # line of the synthesized HTTP/1 head while STILL SHOWING the tester the injection
      # attempt — a malformed response header is a security issue, not noise to hide. gori
      # is a security-testing proxy: it must surface bad bytes, not silently swallow them.
      private def self.visualize_field(s : String) : String
        return s unless s.includes?('\r') || s.includes?('\n')
        s.gsub('\r', "\\r").gsub('\n', "\\n")
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
        authority_override = nil
        regular = [] of {String, String}
        lines[1..]?.try &.each do |field_line|
          next if field_line.empty?
          pair = HeadCodec.header_field(field_line)
          raise Gori::Error.new(unencodable_line(field_line)) unless pair
          raw_name, value = pair
          if raw_name.compare("host", case_insensitive: true) == 0
            authority_override = value unless value.empty?
            next # folded into :authority below; a literal `host` header is illegal in h2
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

      private def self.synth_head(status : Int32, headers : Array({String, String})) : Bytes
        String.build do |io|
          io << "HTTP/2 " << status << "\r\n"
          headers.each { |(n, v)| io << n << ": " << v << "\r\n" }
          io << "\r\n"
        end.to_slice
      end

      private def self.failure(message : String, started : Time::Instant) : Result
        Result.new(Bytes.new(0), nil, nil, elapsed(started), message)
      end

      # A nil socket here means no usable HTTP/2 connection — could be unreachable,
      # an origin that doesn't offer h2 over ALPN, or (for verified https) a cert that
      # failed verification. Spell that out instead of a bare "connect failed".
      private def self.connect_error(scheme : String, host : String, port : Int32, verify : Bool) : String
        base = "h2 connect failed (no h2 negotiated): #{host}:#{port}"
        if scheme == "https" && verify
          "#{base} — host unreachable, the origin doesn't offer HTTP/2 via ALPN, or its TLS certificate failed verification"
        else
          "#{base} — host unreachable or the origin doesn't offer HTTP/2 (h2c) here"
        end
      end

      private def self.elapsed(started : Time::Instant) : Int64
        (Time.instant - started).total_microseconds.to_i64
      end
    end
  end
end
