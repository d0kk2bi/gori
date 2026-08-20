require "../url"
require "../proxy/h2/head_codec"

module Gori
  module Export
    # A captured REQUEST as a ready-to-run `curl` invocation — the serializer behind the
    # TUI's "Copy as → cURL" row (`Tui::CopyMenu`) and `gori run show <id> --format curl`.
    #
    # SURFACE-NEUTRAL on purpose. This used to live entirely inside `src/gori/tui/copy_menu.cr`,
    # which meant the only way for the CLI to emit the same command was to import `Tui::` —
    # or, worse, to write a second curl serializer that would drift from the first the moment
    # either grew a flag. It sits beside `Export::Har` because it is the same kind of thing:
    # bytes gori captured, written out in a shape another tool can run.
    #
    # `Tui::CopyMenu` keeps the menu (the Option records, the wscat row, the response-side
    # formats) and delegates every byte of request parsing and shell quoting here, so the
    # clipboard and the CLI cannot disagree about what this request's curl line is.
    module Curl
      # gori's own annotations on a SYNTHESIZED h2 head (`Proxy::H2::HeadCodec`) — which fields
      # arrived in a trailing HEADERS block, that the origin invented this request in a
      # PUSH_PROMISE, an RFC 8441 `:protocol`. They are gori speaking ABOUT the exchange, not
      # bytes any client put on the wire, so a command that claims to reproduce the request must
      # not send them. Dropped by name rather than by an `x-gori-` prefix sweep: an operator's
      # own header is theirs to send, and these three are the only ones gori writes itself.
      MARKER_HEADERS = [
        Proxy::H2::HeadCodec::TRAILER_MARKER.downcase,
        Proxy::H2::HeadCodec::PUSHED_MARKER.downcase,
        Proxy::H2::HeadCodec::PROTOCOL_MARKER.downcase,
      ]

      # The curl line for one request. `wire` is the request as it'd be sent (CRLF-framed,
      # env-expanded — the bytes repeater uses), `target` the "scheme://host[:port]" base that
      # resolves an origin-form request line ("GET /p HTTP/1.1") into a full URL. nil when there
      # is no resolvable URL, which is the one case there is nothing runnable to hand over.
      def self.text(wire : String, target : String) : String?
        head, body = split_message(wire)
        lines = split_lines(head)
        header_lines = lines.size > 1 ? lines[1..] : [] of String
        method, req_target, version = parse_request_line(lines.first? || "")
        url = resolve_url(req_target, target, header_lines)
        return nil if url.empty?
        command(method, url, header_lines, body, version)
      end

      # A copy-pasteable `curl` invocation reproducing the request. URL first (browser
      # "Copy as cURL" convention), then the protocol flag when the capture was not h1, then -X
      # for the method, each header as -H (dropping Host/Content-Length — curl derives those),
      # then --data-raw for a body. Every argument is single-quoted with embedded quotes
      # escaped, so it survives a paste into any POSIX shell verbatim. Continuation lines keep
      # it readable.
      #
      # EVERY argument means the METHOD too, and that one is not decoration. The method is
      # UNVALIDATED bytes off the wire — `parse_request_head` is `start.split(' ')` with no
      # check at all (`request_token_safe?` exists but is called only by discover / the MCP
      # request builder / the fuzzer's redirect guard, never on the capture path), and the one
      # byte gori does judge is the FIRST, via `looks_like_http_request?`. So every shell
      # metacharacter reaches this line: `` ` ``, `$`, `|`, `&`, `;`, `'`, and CTL/DEL too.
      # (`Import::Builder.reject_inject!` narrows the HAR path to "no CR/LF/NUL" — narrower,
      # still wide open.) Spliced raw, `-X GET;curl|sh` ended the curl command and started a
      # second one IN THE OPERATOR'S SHELL the moment they pasted what gori handed them, which
      # is the one place a hostile capture could aim this command. Quoted like the rest now.
      def self.command(method : String, url : String, header_lines : Array(String),
                       body : String, version : String = "") : String
        parts = ["curl #{shell_quote(url)}"]
        if flag = version_flag(version, url)
          parts << flag
        end
        # Emit -X unless it's a plain bodyless GET (curl's default). A GET *with* a body
        # still needs -X GET, else curl silently promotes the request to POST.
        method_note = nil
        unless method.empty? || (method == "GET" && body.empty?)
          if note = nul_method_note(method, body)
            method_note = note
          else
            parts << "-X #{shell_quote(method)}"
          end
        end
        each_header(header_lines) do |name, value|
          down = name.downcase
          next if down == "host" || down == "content-length"
          next if MARKER_HEADERS.includes?(down)
          parts << "-H #{shell_quote("#{name}: #{value}")}"
        end
        parts << data_argument(body) unless body.empty?
        # LAST, like `data_argument`'s refusal and for the same reason: a `#` comment swallows
        # the ` \` that continues the line, so a note anywhere earlier would truncate the
        # command it is annotating.
        parts << method_note if method_note
        parts.join(" \\\n  ")
      end

      # The refusal for a method holding a NUL, or nil when there is none. Same hole
      # `data_argument` names for the body, on the other end of the same command: `shell_quote`
      # carries every byte inside '…' except 0x00, and an argv is NUL-terminated, so bash
      # TRUNCATES the method there and curl sends a different one than the capture — silently,
      # with `-X 'GET'` on screen looking correct. Reachable on the proxy path only (import
      # refuses NUL); nothing validates it, see `command`.
      #
      # No `-X` is emitted, so curl falls back to its own default, and the note says which.
      private def self.nul_method_note(method : String, body : String) : String?
        return nil unless method.to_slice.includes?(0_u8)
        "# -X omitted: the captured method holds a NUL, which no shell argument can carry — " \
        "bash would truncate it and curl would send #{body.empty? ? "GET" : "POST"} instead. " \
        "Read the request line with --format raw"
      end

      # The protocol flag for a capture whose request line says HTTP/2, else nil. curl
      # negotiates h2 over TLS through ALPN (`--http2`), but cleartext h2c has no negotiation
      # to do — it must be asserted up front, and `--http2` alone would send an h1 request to a
      # server that only speaks h2c. HTTP/1.x needs nothing: it is curl's default.
      private def self.version_flag(version : String, url : String) : String?
        return nil unless version.upcase == "HTTP/2"
        url.starts_with?("https://") ? "--http2" : "--http2-prior-knowledge"
      end

      # The body as a curl argument, or a named refusal. `shell_quote` carries ANY byte verbatim
      # inside '…' except one: 0x00. A shell command line is a NUL-terminated argv, so no quoting
      # can put a NUL into it — bash drops the byte and curl would send a body SHORTER than the
      # one gori captured, with nothing on the line saying so. A captured gRPC/protobuf body has
      # them routinely. So say it. The note is a `#` comment and `--data-raw` is the last part of
      # the command, so a paste still runs (sending no body) instead of sending a different one,
      # and the "Body" row of the same copy menu still hands over the exact bytes.
      private def self.data_argument(body : String) : String
        return "--data-raw #{shell_quote(body)}" unless body.to_slice.includes?(0_u8)
        "# body omitted: #{body.bytesize} bytes holding a NUL, which no shell argument can " \
        "carry; copy \"Body\" instead and pass it with --data-binary @FILE"
      end

      # --- the pure request primitives, shared with Tui::CopyMenu -------------------------

      # Split an HTTP message into {head, body} on the first blank line — CRLF wire
      # form first, bare-LF (an editor snapshot) as a fallback.
      def self.split_message(text : String) : {String, String}
        if idx = text.index("\r\n\r\n")
          {text[0, idx], text[(idx + 4)..]}
        elsif idx = text.index("\n\n")
          {text[0, idx], text[(idx + 2)..]}
        else
          {text, ""}
        end
      end

      # `head` split into lines on LF, each with one trailing CR dropped — what `split(/\r?\n/)`
      # spelled. Hand-rolled for two reasons, both about a head that is not valid UTF-8 (a
      # capture legitimately can be: obs-text in a header value, a latin-1 filename): a Regexp
      # over those bytes RAISES, which is why this used to `scrub` first — and that scrub then
      # REWROTE the operator's bytes, so a "Copy as cURL" `-H` came out carrying the three bytes
      # of U+FFFD where the wire had one. Byte-wise, neither happens.
      def self.split_lines(head : String) : Array(String)
        bytes = head.to_slice
        lines = [] of String
        start = 0
        i = 0
        while i < bytes.size
          if bytes[i] == 0x0a_u8
            stop = (i > start && bytes[i - 1] == 0x0d_u8) ? i - 1 : i
            lines << String.new(bytes[start, stop - start])
            start = i + 1
          end
          i += 1
        end
        lines << String.new(bytes[start, bytes.size - start])
        lines
      end

      # {method, request-target, version} from a request line, best-effort (missing
      # tokens come back empty rather than raising on a hand-typed partial request).
      def self.parse_request_line(line : String) : {String, String, String}
        parts = line.strip.split(' ')
        {parts[0]? || "", parts[1]? || "", parts[2]? || ""}
      end

      # The full URL for the request: an absolute-form request target as-is, else the
      # target base joined with the origin-form path (falling back to the Host header
      # when no target base is set — a hand-authored request). "" when unresolvable.
      def self.resolve_url(req_target : String, target : String, header_lines : Array(String)) : String
        # Case-insensitive via the one home: an `HTTP://acme.test/x` target used to fall
        # through and get a base prefixed, yielding `https://acme.test/HTTP://acme.test/x`
        # on the operator's clipboard.
        return req_target if Gori::Url.absolute_form?(req_target)
        base = authority_base(target.strip)
        if base.empty?
          host = header_value(header_lines, "host")
          base = host ? "http://#{host}" : ""
        end
        return "" if base.empty?
        base = base.rstrip('/')
        return base if req_target.empty? || req_target == "*"
        req_target.starts_with?('/') ? "#{base}#{req_target}" : "#{base}/#{req_target}"
      end

      # scheme://host[:port] with any path/query the user may have pasted into the target
      # field stripped — the send path (FlowRequest.parse_target) uses only scheme/host/port,
      # so the copied URL must too, else it doubles the request-line path onto the target's.
      private def self.authority_base(target : String) : String
        sep = target.index("://")
        return target unless sep
        slash = target.index('/', sep + 3)
        slash ? target[0, slash] : target
      end

      # The first matching header's value (case-insensitive name), or nil.
      def self.header_value(header_lines : Array(String), name : String) : String?
        want = name.downcase
        each_header(header_lines) { |hname, value| return value if hname.downcase == want }
        nil
      end

      # Yield each well-formed header line as {stripped name, stripped value}; lines
      # without a colon (blank/continuation) are skipped. ONE parse convention shared by
      # `command`, the copy menu's Cookie row and the wscat builder, so they can't drift.
      def self.each_header(header_lines : Array(String), & : String, String ->) : Nil
        header_lines.each do |line|
          name, sep, value = line.partition(":")
          next if sep.empty?
          n = name.strip
          next if n.empty?
          yield n, value.strip
        end
      end

      # POSIX single-quote: wrap in '…' and rewrite each embedded ' as '\'' so the
      # result is one safe shell word regardless of what's inside (incl. newlines).
      #
      # BYTE SAFETY — this was `s.gsub("'", "'\\''")`. `String#gsub(String, String)` delegates to
      # the CHAR overload as soon as the needle is ONE BYTE long, and Crystal's char iteration
      # substitutes the three bytes of U+FFFD for every byte that is not valid UTF-8. `s` here is
      # a CAPTURE — `--data-raw` gets the request body straight off the wire — so "Copy as cURL"
      # of a binary body handed the operator a command that did not reproduce the request.
      # Measured on body `a='x'&bin=<ff fe 01 02>`:
      #
      #   before  … 26 62 69 6e 3d ef bf bd ef bf bd 01 02   4 captured bytes → 8
      #   after   … 26 62 69 6e 3d ff fe 01 02               intact
      #
      # Scanning and splicing BYTES is the rule `Fuzz::Plan.wrap_token` already writes down.
      def self.shell_quote(s : String) : String
        bytes = s.to_slice
        io = IO::Memory.new(bytes.size + 2)
        io << '\''
        bytes.each do |b|
          if b == 0x27_u8 # '
            io << "'\\''"
          else
            io.write_byte(b)
          end
        end
        io << '\''
        String.new(io.to_slice)
      end
    end
  end
end
