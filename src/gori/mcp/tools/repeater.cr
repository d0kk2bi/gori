require "json"
require "../../env"
require "../../store"

module Gori
  module MCP
    class Tools
      private def create_repeater(h) : Result
        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) if issue_id.nil? && present?(h, "issue_id")
        flow_id = int(h, "flow_id")
        return Result.new(id_error(h, "flow_id"), is_error: true) if flow_id.nil? && present?(h, "flow_id")

        target = str(h, "target")
        request = str(h, "request")

        if issue_id
          issue = store.get_issue(issue_id)
          return not_found("no issue with id #{issue_id}") unless issue
          if fid = issue.flow_id
            flow_id = fid
          elsif target.nil? || target.empty? || request.nil? || request.empty?
            return Result.new("issue #{issue_id} has no associated flow_id", is_error: true)
          end
        end

        http2_val = bool(h, "http2")
        http2 = http2_val || false
        auto_cl_val = bool(h, "auto_content_length")
        auto_cl = (auto_cl_val.nil? && !present?(h, "auto_content_length")) ? true : !!auto_cl_val
        ws_messages_override = nil.as(Array(Store::WsOutMessage)?)

        if flow_id
          flow = store.get_flow(flow_id)
          return not_found("no flow with id #{flow_id}") unless flow

          # Seed through `FlowRequest.build`, exactly as `gori run repeater create --flow` and
          # `send_request{flow_id}` do. Hand-assembling head+body here skipped all three things
          # that function exists for:
          #   * `resync_truncated_head` — a capture cut at CAPTURE_MAX keeps its original
          #     `Transfer-Encoding: chunked` over a body with no terminating 0-chunk (or a
          #     Content-Length promising bytes that no longer exist), so the send blocked for
          #     the full 30 s io_timeout and put a partial chunked stream on the wire. That
          #     function's stated reason for existing is "so the repeater terminates instead
          #     of hanging"; this was the one caller that did not get it.
          #   * `origin_form_bytes` — every plain-HTTP flow gori captures has an ABSOLUTE-form
          #     request line (that is how a proxy client writes it), which was then sent
          #     verbatim to an origin that expects origin-form.
          #   * `build_target` — this was a third hand-rolled copy of the authority formula,
          #     without the ws/wss default-port fold or IPv6 re-bracketing the shared one has.
          built = Repeater::FlowRequest.build(flow)

          target = built.target if target.nil? || target.empty?
          request = String.new(built.bytes) if request.nil? || request.empty?
          http2 = built.http2 if http2_val.nil?
          # `built.sni` is deliberately NOT seeded here: `gori run repeater create --flow`
          # takes SNI from the operator's flag alone, and this tool is its MCP twin.

          if flow.row.status == 101 && !present?(h, "ws_out_messages")
            # Opcode and raw bytes, both kept. The `&& m.text?` filter dropped every captured
            # BINARY out-frame with no warning at all (the CLI at least printed one), and the
            # `.scrub` rewrote an invalid-UTF-8 TEXT payload to U+FFFD before it was stored —
            # so a §8.1/§5.6 test case could not be seeded into a repeater from MCP.
            ws_messages_override = store.ws_messages(flow_id).select { |m| m.direction == "out" }
              .map { |m| Store::WsOutMessage.new(m.opcode, m.payload) }
          end
        end

        return Result.new("missing required 'target'", is_error: true) if target.nil? || target.empty?
        return Result.new("missing required 'request'", is_error: true) if request.nil? || request.empty?

        sni = str(h, "sni")

        position = int(h, "position")
        if position.nil?
          return Result.new(id_error(h, "position"), is_error: true) if present?(h, "position") # present but non-integer
          position = store.repeaters_meta.size.to_i64
        elsif position < Int32::MIN || position > Int32::MAX
          return Result.new("'position' out of range", is_error: true)
        end

        # Apply Env.mask_secrets
        masked_target = Env.mask_secrets(target)
        masked_request = Env.mask_secrets(request)
        masked_sni = sni.try { |s| Env.mask_secrets(s) }
        name = str(h, "name").try { |n| Env.mask_secrets(n) }

        # WebSocket mode check
        is_ws = Repeater::WsEngine.upgrade_request?(masked_request)

        id = store.insert_repeater(
          target: masked_target,
          request: masked_request.to_slice,
          http2: http2,
          auto_cl: auto_cl,
          flow_id: flow_id,
          position: position.to_i32,
          sni: masked_sni
        )

        return busy("failed to persist repeater (store busy or unwritable)") if id == 0

        if issue_id
          store.add_link(Store::LinkOwnerKind::Issue, issue_id,
            Store::LinkRefKind::Repeater, id)
        end

        if name && !name.empty?
          store.set_repeater_name(id, name)
        end

        # WebSocket messages handling
        if is_ws
          messages = present?(h, "ws_out_messages") ? ws_out_messages_arg(h) : (ws_messages_override || [] of Store::WsOutMessage)
          unless messages.empty?
            store.update_repeater_ws_messages(id, messages)
          end
        end

        # Derive summary from the MASKED request — the raw request may carry a secret
        # in the request-target (e.g. ?token=…), and this field is returned to the LLM.
        line = masked_request.each_line.first?.try(&.strip) || ""
        parts = line.split(' ')
        s = "#{parts[0]?} #{parts[1]?}".strip
        s = line if s.empty?
        summary = s.size > 80 ? "#{s[0, 79]}…" : s

        Result.new(JSON.build { |j|
          j.object do
            j.field "id", id
            j.field "name", name || ""
            j.field "target", masked_target
            j.field "summary", summary
            j.field "position", position
          end
        })
      end

      # The `ws_out_messages` argument, in any of the three forms the schema advertises: an
      # array of strings, a newline-separated string, or an array of objects.
      #
      # The OBJECT form is what makes a binary frame expressible from MCP at all. Every
      # string form is a TEXT frame (opcode 1) — that was the only shape this tool could ever
      # produce, so `{"payload_base64": …}` (opcode 2 unless `opcode` says otherwise) is the
      # one addition, and it is where a later fin/rsv/mask field belongs too.
      private def ws_out_messages_arg(h) : Array(Store::WsOutMessage)
        if arr = h["ws_out_messages"]?.try(&.as_a?)
          return arr.compact_map { |item| ws_out_message_item(item) }
        end
        return [] of Store::WsOutMessage unless str_val = str(h, "ws_out_messages")
        str_val.split('\n').compact_map { |l| l.strip.empty? ? nil : Store::WsOutMessage.text(l) }
      end

      private def ws_out_message_item(item : JSON::Any) : Store::WsOutMessage?
        if text = item.as_s?
          return Store::WsOutMessage.text(text)
        end
        return nil unless obj = item.as_h?
        if b64 = obj["payload_base64"]?.try(&.as_s?)
          decoded = Base64.decode(b64) rescue return nil
          return Store::WsOutMessage.new(obj["opcode"]?.try(&.as_i?) || 2, decoded)
        end
        text = obj["text"]?.try(&.as_s?) || return nil
        Store::WsOutMessage.new(obj["opcode"]?.try(&.as_i?) || 1, text.to_slice)
      end

      private def update_repeater(h) : Result
        id = int(h, "id")
        return Result.new("missing or invalid required 'id'", is_error: true) unless id

        existing = store.get_repeater(id)
        return not_found("no repeater with id #{id}") unless existing

        target = str(h, "target") || existing.target
        request = str(h, "request") || String.new(existing.request)
        # An explicitly-passed empty string is truthy in Crystal, so guard it here to
        # mirror create_repeater's invariant — a blank target/request can't be sent.
        return Result.new("target must not be empty", is_error: true) if target.empty?
        return Result.new("request must not be empty", is_error: true) if request.empty?

        http2 = if present?(h, "http2")
                  bool(h, "http2") || false
                else
                  existing.http2?
                end

        auto_cl = if present?(h, "auto_content_length")
                    bool(h, "auto_content_length") || false
                  else
                    existing.auto_content_length?
                  end

        sni = present?(h, "sni") ? str(h, "sni") : existing.sni

        masked_target = Env.mask_secrets(target)
        masked_request = Env.mask_secrets(request)
        masked_sni = sni.try { |s| Env.mask_secrets(s) }
        name = present?(h, "name") ? str(h, "name").try { |n| Env.mask_secrets(n) } : existing.name

        unless store.update_repeater(
                 id: id,
                 target: masked_target,
                 request: masked_request.to_slice,
                 http2: http2,
                 auto_cl: auto_cl,
                 sni: masked_sni
               )
          return busy("repeater NOT updated (store busy or unwritable); it is unchanged")
        end

        if present?(h, "name")
          store.set_repeater_name(id, name)
        end

        # Tags are the TUI's subtab labels (the `t` key) — the grouping a human uses to keep a
        # long session navigable. An explicit blank clears them.
        if present?(h, "tags")
          tags = str(h, "tags").try { |t| Env.mask_secrets(t).strip }
          store.set_repeater_tags(id, tags.presence)
        end

        # WebSocket messages handling
        store.update_repeater_ws_messages(id, ws_out_messages_arg(h)) if present?(h, "ws_out_messages")

        # Derive the summary from the MASKED request, like create_repeater: the raw request may
        # carry a secret in the request-target (e.g. ?token=…) and this field goes to the LLM.
        line = masked_request.each_line.first?.try(&.strip) || ""
        parts = line.split(' ')
        s = "#{parts[0]?} #{parts[1]?}".strip
        s = line if s.empty?
        summary = s.size > 80 ? "#{s[0, 79]}…" : s

        Result.new(JSON.build { |j|
          j.object do
            j.field "id", id
            j.field "name", name || ""
            j.field "target", masked_target
            j.field "summary", summary
            j.field "position", existing.position
          end
        })
      end

      private def delete_repeater(h) : Result
        id = int(h, "id")
        return Result.new("missing or invalid required 'id'", is_error: true) unless id

        existing = store.get_repeater(id)
        return not_found("no repeater with id #{id}") unless existing

        return busy("repeater NOT deleted (store busy or unwritable); it is unchanged") unless store.delete_repeater(id)
        Result.new(JSON.build { |j| j.object { j.field "success", true } })
      end
    end
  end
end
