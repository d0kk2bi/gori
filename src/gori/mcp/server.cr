require "json"
require "log"
require "../store"
require "./tools"

module Gori
  module MCP
    # A Model Context Protocol server over stdio: JSON-RPC 2.0, one compact JSON
    # message per line on `input`, responses on `output`. STDOUT is the protocol
    # channel — callers MUST keep it pure (logs go to STDERR). IO is injectable so
    # the server is unit-testable with IO::Memory.
    class Server
      Log = ::Log.for("mcp")

      # Newest spec revision we implement. Our surface (initialize/tools.list/
      # tools.call/ping) is identical across recent revisions, so we echo the
      # client's requested version when it is one we recognise, and never
      # hard-fail on a mismatch.
      PROTOCOL_VERSION = "2025-06-18"

      # Revisions whose surface we're compatible with. Per the MCP lifecycle the
      # server MUST answer initialize with a version it actually supports: we
      # echo the client's version only when it's in this set, else fall back to
      # PROTOCOL_VERSION — so a client probing "1999-01-01" can't conclude we
      # speak a revision we don't.
      SUPPORTED_VERSIONS = {"2025-06-18", "2025-03-26", "2024-11-05"}

      EMPTY_ARGS = JSON::Any.new({} of String => JSON::Any)

      def initialize(@store : Store? = nil, *, allow_actions : Bool, verify_upstream : Bool,
                     @project_name : String? = nil, @project_slug : String? = nil,
                     @db_path : String? = nil, @selection_source : String? = nil,
                     @workspace_root : String? = nil, @project_id : String? = nil,
                     @input : IO = STDIN, @output : IO = STDOUT)
        @allow_actions = allow_actions
        @tools = Tools.new(@store, allow_actions, verify_upstream,
          project_name: @project_name, project_slug: @project_slug, db_path: @db_path,
          selection_source: @selection_source, workspace_root: @workspace_root,
          project_id: @project_id)
        @initialized = false
        # Set when the output pipe breaks (client vanished mid-write): the loop then
        # stops rather than thrashing on a dead stream or raising an unhandled error.
        @closed = false
        # Non-nil only while a batch is being dispatched: `send` collects into it instead of
        # writing, so the members' responses leave as the one array the batch is owed.
        @batch = nil.as(Array(String)?)
      end

      # Reads until EOF on `input` (client closed the pipe). Each line is parsed
      # and dispatched independently; a bad line never stops the loop. A broken
      # transport (the client process died) ends the session cleanly — a normal
      # shutdown, not a crash to surface as an unhandled backtrace.
      def run : Nil
        @input.each_line do |line|
          break if @closed
          line = line.strip
          next if line.empty?
          handle_line(line)
          break if @closed
        end
      rescue ex : IO::Error
        Log.info { "mcp: input stream closed (#{ex.message})" }
      end

      private def handle_line(line : String) : Nil
        root = begin
          JSON.parse(line)
        rescue ex : JSON::ParseException
          # Answer with the request's OWN id when the line still carries a readable one.
          # A perfectly legal JSON number outside Int64 range (`{"limit": 1e30}` spelled out,
          # which an LLM emits for "no limit") makes Crystal's parser reject the whole line —
          # so a request that is only an ARGUMENT mistake used to come back `id: null`, and a
          # strict client with a pending promise for that id never resolved it. The agent hung
          # instead of seeing the error. See `recover_id`.
          return write_error(recover_id(line), -32700, "Parse error: #{ex.message}")
        end

        if batch = root.as_a?
          handle_batch(batch)
        else
          handle_message(root)
        end
      end

      # A JSON-RPC 2.0 batch: an ARRAY of messages, answered by ONE array of the responses
      # the member requests produced.
      #
      # SUPPORTED_VERSIONS advertises `2025-03-26`, the one MCP revision where receiving
      # batches is mandatory (2025-06-18 removed it again) — and we echo that version back
      # whenever a client asks for it. Without this, every batch fell through to
      # handle_message's object check and came back as a SINGLE `Invalid Request` at id
      # `null`: not one of the ids in the batch, so a client holding a promise per request
      # resolved none of them and the session hung on a revision we had just claimed.
      #
      # Members are dispatched in order through the same path a lone line takes, so a bad
      # member yields its own error object beside its siblings' results rather than voiding
      # the batch.
      private def handle_batch(items : Array(JSON::Any)) : Nil
        # An empty batch names no request to answer, so the single null-id error IS the
        # spec's answer here (unlike the case above, where ids existed and were thrown away).
        return write_error(nil, -32600, "Invalid Request: empty batch") if items.empty?

        collected = [] of String
        @batch = collected
        begin
          items.each { |item| handle_message(item) }
        ensure
          @batch = nil
        end

        # All-notification batches get no response at all — sending `[]` back is explicitly
        # forbidden, and a client that reads one as a malformed frame drops the connection.
        return if collected.empty?
        send("[#{collected.join(',')}]")
      end

      private def handle_message(root : JSON::Any) : Nil
        id = nil.as(JSON::Any?)
        obj = root.as_h?
        return write_error(nil, -32600, "Invalid Request") unless obj

        id = obj["id"]?
        method = obj["method"]?.try(&.as_s?)
        params = obj["params"]?

        unless method
          # No `method` at all is a MALFORMED message, not a notification — a notification is
          # one that omits `id` while still naming a method, and this one may omit both. It is
          # answered at whatever id it carried, or at null when it carried none. Staying silent
          # for the id-less case cost a batch one array element, and a client that correlates
          # responses to members BY POSITION then pairs every later response with the wrong
          # request — worse than the error it was trying not to send.
          return write_error(id, -32600, "Invalid Request: missing method")
        end

        if id
          handle_request(id, method, params)
        else
          handle_notification(method, params)
        end
      rescue ex
        Log.error(exception: ex) { "dispatch error" }
        # Never leave a request with an id hanging — the client would block forever.
        write_error(id, -32603, "Internal error: #{ex.message}") if id
      end

      private def handle_request(id : JSON::Any, method : String, params : JSON::Any?) : Nil
        case method
        when "initialize" then handle_initialize(id, params)
        when "ping"       then write_result(id) { |j| j.object { } }
        when "tools/list" then handle_tools_list(id)
        when "tools/call" then handle_tools_call(id, params)
        else                   write_error(id, -32601, "Method not found: #{method}")
        end
      rescue ex
        Log.error(exception: ex) { "request #{method} failed" }
        write_error(id, -32603, "Internal error: #{ex.message}")
      end

      private def handle_notification(method : String, params : JSON::Any?) : Nil
        @initialized = true if method == "notifications/initialized"
        # All other notifications are accepted silently (no response, ever).
      end

      private def handle_initialize(id : JSON::Any, params : JSON::Any?) : Nil
        client_ver = obj_field(params, "protocolVersion").try(&.as_s?)
        version = client_ver && SUPPORTED_VERSIONS.includes?(client_ver) ? client_ver : PROTOCOL_VERSION
        write_result(id) do |j|
          j.object do
            j.field "protocolVersion", version
            j.field("capabilities") { j.object { j.field("tools") { j.object { } } } }
            j.field "serverInfo" do
              j.object do
                j.field "name", "gori"
                j.field "version", Gori::VERSION
              end
            end
            j.field "instructions", instructions_text
          end
        end
      end

      # Surfaced at the handshake so the client/model knows up front what this server
      # exposes — in particular whether the (otherwise simply absent) action tools are
      # disabled by read-only mode, rather than discovering it only on a rejected call.
      private def instructions_text : String
        selected = if @store.nil?
                     " No project is bound yet. Call list_projects to see available projects, " \
                     "create_project to make one (auto-binds when unbound), or switch_project " \
                     "before using traffic tools (list_history, send_request, …). Pure tools " \
                     "(decode, jwt_*, ql_reference) work immediately."
                   elsif @project_name || @project_slug
                     " This server is pinned to project #{@project_name || @project_slug}#{" [#{@project_slug}]" if @project_slug}" \
                     " via #{@selection_source || "an explicit database"}#{" for workspace #{@workspace_root}" if @workspace_root}."
                   else
                     " Project selection source: #{@selection_source || "unknown"}; call project_info before using data."
                   end
        base = "gori MCP exposes the selected project's captured HTTP traffic " \
               "(history, flows, sitemap, scope, issues, notes, match&replace rules), plus a " \
               "pure `decoder` encode/decode/hash tool. Call ql_reference before " \
               "writing list_history/list_sitemap queries. Timestamps include unix " \
               "microseconds plus *_iso RFC3339 fields where available.#{selected}"
        if @allow_actions
          "#{base} Action tools are enabled: send_request (supports flow_id/repeater_id), " \
          "send_websocket (executes a persisted WS repeater), " \
          "fuzz_*, mine_*, create/update_issue, and create/delete_rule + set_rule_enabled " \
          "make real outbound requests or mutate issues/rules. Active requests " \
          "(send_request, send_websocket, fuzz, mine) are gated by the project scope: a target " \
          "outside — or without — a configured scope is refused (SCOPE_BLOCKED) unless you pass " \
          "allow_unscoped:true. Projects can be managed via list/create/switch/delete_project."
        else
          "#{base} Read-only mode: action tools (send_request, send_websocket, fuzz_*, mine_*, " \
          "create/update_issue, create/delete_rule) are disabled — restart without --read-only to enable them. " \
          "switch_project (and create_project when unbound) remain available so you can still pick a project to inspect."
        end
      end

      private def handle_tools_list(id : JSON::Any) : Nil
        write_result(id) do |j|
          j.object { j.field("tools") { @tools.list(j) } }
        end
      end

      private def handle_tools_call(id : JSON::Any, params : JSON::Any?) : Nil
        name = obj_field(params, "name").try(&.as_s?)
        return write_error(id, -32602, "tools/call: missing 'name'") unless name
        args = tool_arguments(params)
        return write_error(id, -32602,
          "tools/call: 'arguments' must be an object (or a JSON-encoded one)") unless args
        result = @tools.call(name, args)
        write_result(id) do |j|
          j.object do
            j.field("content") do
              j.array do
                j.object { j.field "type", "text"; j.field "text", result.text }
              end
            end
            if result.is_error && (code = result.error_code)
              # Machine-processable error alongside the human `text` (the tools
              # layer guarantees a stable code on every plain-message error).
              j.field("structuredContent") { emit_error_object(j, result, code) }
            elsif structured = structured_content(result.text)
              j.field("structuredContent") { structured.to_json(j) }
            end
            j.field "isError", result.is_error
          end
        end
      end

      # `params.arguments` as the object the tools layer reads, or nil when it is a shape that
      # is not an argument list at all.
      #
      # An `as_h?`-only read answered nil for every other shape, and `Tools#call` substituted
      # an EMPTY hash for it — so a client that stringifies its arguments (which happens, and
      # which `RequestBuilder.header_pairs` already accepts one level down) had every argument
      # silently dropped and was told "missing required 'id'" for a call that named `id`. The
      # agent then "fixed" an argument it had sent correctly, in a loop. Parse the encoded
      # form; refuse anything else HERE, as a protocol error, rather than run a tool with none
      # of the arguments it was called with.
      #
      # Absent / null / blank all stay "no arguments" — a tool with only optional arguments is
      # legitimately called that way, and `""` is what an LLM emits for it.
      private def tool_arguments(params : JSON::Any?) : JSON::Any?
        raw = obj_field(params, "arguments")
        return EMPTY_ARGS if raw.nil? || raw.raw.nil?
        return raw if raw.as_h?
        if s = raw.as_s?
          return EMPTY_ARGS if s.strip.empty?
          parsed = (JSON.parse(s) rescue nil)
          return parsed if parsed && parsed.as_h?
        end
        nil
      end

      # The structured-error contract: {error_code, message, field?, retryable,
      # details?}. `message` mirrors content[0].text so a caller reading only
      # structuredContent still gets the human summary.
      private def emit_error_object(j : JSON::Builder, result : Tools::Result, code : String) : Nil
        j.object do
          j.field "error_code", code
          j.field "message", result.text
          j.field "field", result.field if result.field
          j.field "retryable", result.retryable
          if d = result.details
            j.field("details") { d.to_json(j) }
          end
        end
      end

      # MCP structuredContent is an object. Preserve the text block for older
      # clients, while giving newer clients parsed data directly so callers do
      # not have to JSON-decode content[0].text a second time. Array/scalar tool
      # payloads are wrapped to satisfy the object shape required by MCP.
      private def structured_content(text : String) : JSON::Any?
        parsed = JSON.parse(text)
        return parsed if parsed.as_h?
        if parsed.as_a?
          return JSON::Any.new({"items" => parsed})
        end
        JSON::Any.new({"value" => parsed})
      rescue JSON::ParseException
        nil
      end

      # Field of a JSON object that may be nil/non-object — never raises.
      private def obj_field(any : JSON::Any?, key : String) : JSON::Any?
        any.try(&.as_h?).try(&.[key]?)
      end

      private def write_result(id : JSON::Any?, &block : JSON::Builder ->) : Nil
        send(JSON.build do |j|
          j.object do
            j.field "jsonrpc", "2.0"
            emit_id(j, id)
            j.field("result") { block.call(j) }
          end
        end)
      end

      private def write_error(id : JSON::Any?, code : Int32, message : String) : Nil
        send(JSON.build do |j|
          j.object do
            j.field "jsonrpc", "2.0"
            emit_id(j, id)
            j.field("error") { j.object { j.field "code", code; j.field "message", message } }
          end
        end)
      end

      # Echoes the request id verbatim (int stays int, string stays string); null
      # when we have none (e.g. a parse error before we could read it).
      private def emit_id(j : JSON::Builder, id : JSON::Any?) : Nil
        j.field("id") { id ? id.to_json(j) : j.null }
      end

      # A TOP-LEVEL `"id"` scraped out of a line the JSON parser refused, so a parse error can
      # still be correlated by the client that sent it. Deliberately textual and deliberately
      # narrow: the line is by definition not parseable, so there is no structure to walk. The
      # anchor is `{"jsonrpc":…,"id":…` — the id must appear before `"method"`/`"params"`,
      # which is where every client this speaks to puts it, and which keeps an `"id"` nested
      # inside a tool ARGUMENT (get_flow's own `id`, an issue id, …) from being mistaken for
      # the envelope's. Nil when nothing matches: a wrong id is worse than none.
      private def recover_id(line : String) : JSON::Any?
        # A line that OPENS as an array is a BATCH, and its first `"id"` belongs to the first
        # MEMBER — there is no envelope id to recover. Answering the whole unparseable batch
        # under that one id resolves exactly one of the client's pending promises and strands
        # every other member: the same hang batch support exists to prevent, arrived at from
        # the other side. A batch parse error is answered at id null, which is also what
        # JSON-RPC asks for when the request cannot be read.
        return nil if line.lstrip.starts_with?('[')
        head = line[0, {line.index(%("method")) || line.size, line.index(%("params")) || line.size}.min]
        m = head.match(/"id"\s*:\s*(?:(-?\d{1,18})|"([^"\\]{0,128})")/)
        return nil unless m
        if n = m[1]?
          n.to_i64?.try { |i| JSON::Any.new(i) }
        else
          m[2]?.try { |s| JSON::Any.new(s) }
        end
      end

      # Last line of defence for the transport's UTF-8 contract. Every emit site that
      # touches outside-origin text already routes through `Serialize.text`; this catches
      # the one a future change forgets. A single invalid byte anywhere in the payload
      # makes a strict client reject the WHOLE line, so a lossy U+FFFD in one field beats
      # losing the response. `valid_encoding?` is ~13x cheaper than `scrub` and the
      # overwhelmingly common case, so the scrub only runs when something slipped through.
      private def wire_safe(payload : String) : String
        return payload if payload.valid_encoding?
        Log.warn { "mcp: response carried invalid UTF-8; scrubbed at the transport (an emit site is missing Serialize.text)" }
        payload.scrub
      end

      private def send(payload : String) : Nil
        return if @closed
        # Inside a batch this is one member's response, not a frame: buffer it for
        # handle_batch, which emits the array through this same method once. Deliberately
        # NOT wire_safe'd here — the joined array gets one pass below, and `[`, `,` and `]`
        # cannot introduce invalid UTF-8, so scanning each member too would walk a
        # multi-megabyte batch twice for the same answer.
        if batch = @batch
          batch << payload
          return
        end
        @output.puts(wire_safe(payload)) # newline framing
        @output.flush                    # or the client blocks on the unterminated line
      rescue ex : IO::Error
        # The client is gone (broken pipe). Stop writing and let the run loop end
        # cleanly instead of unwinding an unhandled exception out of a handler.
        @closed = true
        Log.info { "mcp: output stream closed (#{ex.message})" }
      end
    end
  end
end
