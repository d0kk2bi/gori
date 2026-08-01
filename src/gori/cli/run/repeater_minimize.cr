# `gori run repeater minimize` — strip the noise out of a saved repeater request while
# keeping the response essentially the same (Caido-"squash"-style). Drives the same
# `Repeater::Minimize` engine as the TUI's Space→M, so a CLI run and a TUI run produce the
# same trimmed request for the same session.
module Gori
  module CLI
    module Run
      private def self.cmd_repeater_minimize(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        insecure = false
        apply = false
        verbatim = false
        format = :text
        allow_unscoped = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run repeater minimize <repeater-id> [options]\n\n" \
                     "Strip cosmetic headers, tracking-cookie crumbs, and unused query/body params\n" \
                     "from a saved repeater request, keeping the response within tolerance of a\n" \
                     "calibrated baseline. SENDS MANY REAL REQUESTS (capped at #{Repeater::Minimize::SEND_CAP}).\n" \
                     "Prints the trimmed request; pass --apply to also save it back to the session."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--apply", "Write the minimized request back into the repeater session") { apply = true }
          p.on("--verbatim", "Send the stored bytes as-is: no $VAR expansion, no Content-Length resync (same meaning as `repeater send --verbatim`; body params stop being candidates because their framing could not be kept honest)") { verbatim = true }
          p.on("-k", "--insecure", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--allow-unscoped", "Minimize even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run repeater minimize: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run repeater minimize: missing value for #{f}" }
        end
        parser.parse(args)

        id_s = positional.first? || abort("gori run repeater minimize: <repeater-id> is required")
        id = id_s.to_i64? || abort("gori run repeater minimize: invalid repeater id #{id_s.inspect}")

        store = open_store(resolve_read_project(project_name, db_path))
        # HostOverrides.load snapshots rows into memory, so it is safe to keep past the close.
        # Loaded from the SAME open that fetched `rec` rather than via cli_host_overrides,
        # which returns nil without an explicit --project/--db — a repeater session always
        # belongs to a resolved project, so the overrides must not depend on the flag.
        rec, host_overrides = begin
          {store.get_repeater(id), Gori::HostOverrides.load(store)}
        ensure
          store.close
        end
        abort "gori run repeater minimize: no repeater session ##{id}" unless rec
        outbound = project_outbound(project_name, db_path, allow_unscoped)

        text = String.new(rec.request)
        scheme, host, port = minimize_target_or_abort(id, rec, text, outbound, verbatim)
        # `--verbatim` means exactly what it means on `repeater send`: the stored bytes ARE
        # the message. So the resolver stops expanding AND stops re-framing, and `auto_cl`
        # goes off with it — which also takes body params out of the candidate set, because
        # removing one without re-lengthing the body would put a request on the wire whose
        # Content-Length disagreed with it for a reason the operator did not choose.
        # (`session_plan_options` folds the same two flags together the same way.)
        auto_cl = !verbatim && rec.auto_content_length?
        # Mirrors the TUI's resolve: env-expand, then Content-Length resync only when the
        # session has Auto-CL on (the same gate that lets body params be removed at all).
        # `Minimize.run` hands its `resolve` the request LF-normalized (its text helpers are
        # written against that form) and restores the operator's terminator only on the
        # REPORT. `Env.expand_wire` re-terminates the head with CRLF, so the non-verbatim path
        # never noticed; a verbatim resolver that just took the bytes would have put a
        # CRLF-stored session on the wire bare-LF — inventing the very desync primitive this
        # flag exists to preserve. So restore the terminator here, by the same rule
        # `Minimize#restore_eol` uses, and the wire and the printed report agree.
        stored_crlf = text.includes?("\r\n")
        # …with the one case that rule cannot carry: a head whose lines DISAGREE (some CRLF,
        # some bare LF) is itself a smuggling shape, and minimize's LF round-trip flattens it
        # to all-CRLF. Nothing here can undo that — the algorithm rebuilds the head — so say
        # it rather than let `--verbatim` imply a byte-exactness it is not delivering.
        if verbatim && stored_crlf && mixed_line_endings?(text)
          STDERR.puts "gori run repeater minimize: session ##{id}'s head mixes CRLF and bare-LF " \
                      "line endings; minimize rebuilds the head, so every line is sent CRLF-terminated. " \
                      "Use `gori run repeater send #{id} --verbatim` for a byte-exact replay."
        end
        resolve = ->(t : String) do
          if verbatim
            stored_crlf ? restore_head_crlf(t) : t.to_slice
          else
            raw = Env.expand_wire(t)
            auto_cl ? Repeater::FlowRequest.resync_content_length(raw) : raw
          end
        end
        # Fuzz::Sender applies the Outbound gate (Sandbox / exclude) at the socket seam;
        # CappedBackend bounds total sends. Same stack the TUI builds.
        backend = Fuzz::CappedBackend.new(
          Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port), outbound, rec.http2?,
            !insecure, rec.sni.try { |v| Env.expand(v) }, timeout: 10.seconds,
            overrides: host_overrides),
          Repeater::Minimize::SEND_CAP)

        meter = STDERR.tty?
        report = Repeater::Minimize.run(text, auto_cl: auto_cl, resolve: resolve, backend: backend) do |progress|
          if meter
            STDERR.print "\r[minimize] #{progress.done}/#{progress.total} candidates"
            STDERR.flush
          end
        end
        STDERR.print "\r\e[K" if meter
        outbound.close

        if apply && !report.aborted && !report.removed.empty?
          w = open_store(resolve_read_project(project_name, db_path))
          begin
            w.update_repeater(id: id, target: rec.target, request: report.minimized_text.to_slice,
              http2: rec.http2?, auto_cl: auto_cl, sni: rec.sni)
          ensure
            w.close
          end
        end
        # The report is rendered through the SAME resolver the search used, so the request
        # shown is the request that was tested. It used to print `minimized_text` raw — the
        # SOURCE form — which on a session holding a captured `$where`/CL-22 body printed a
        # 2-byte body under a Content-Length of 22: neither what went on the wire during the
        # search nor what a later `repeater send` would produce. `--apply` still stores the
        # source form (that is what the session row holds, and re-resolving it on every send
        # is the point of storing it).
        report_repeater_minimize(id, report, format, apply, resolve)
        exit 1 if report.aborted
      end

      # Put CRLF terminators back on the HEAD of a `Minimize` working text, leaving the body
      # byte-exact. The same split, and the same reason, as `Env.expand_wire`'s: in the head a
      # 0x0A is a line ending, in the body it is a byte.
      #
      # Needed because `Minimize` hands its `resolve` proc two different forms — the
      # LF-normalized working text during the search, and `restore_eol`'s already-CRLF text in
      # the report — so the step has to be idempotent (LF-normalize first, or the second call
      # produces `\r\r\n`). Restoring the head ALONE also undoes, for the bytes this command
      # sends and prints, `restore_eol`'s blanket `gsub("\n", "\r\n")` over the BODY: a
      # captured body ending in a bare LF under a deliberately-short Content-Length came back
      # one byte longer, which is the CL-desync evidence `--verbatim` exists to preserve.
      private def self.restore_head_crlf(text : String) : Bytes
        bytes = text.gsub("\r\n", "\n").to_slice
        boundary = Env.head_body_boundary(bytes)
        head = Env.normalize_crlf(bytes[0...boundary])
        return head if boundary >= bytes.size
        body = bytes[boundary..]
        io = IO::Memory.new(head.size + body.size)
        io.write(head)
        io.write(body)
        io.to_slice
      end

      # Does the HEAD carry both CRLF- and bare-LF-terminated lines? Head only: a raw 0x0A in
      # a body is a byte, not a line ending (`Env.expand_wire` splits on the same boundary and
      # for the same reason), and judging the whole request would flag every binary body.
      private def self.mixed_line_endings?(text : String) : Bool
        head = String.new(text.to_slice[0...Env.head_body_boundary(text.to_slice)])
        crlf = false
        lf = false
        pos = 0
        while nl = head.index('\n', pos)
          (nl > 0 && head[nl - 1] == '\r') ? (crlf = true) : (lf = true)
          pos = nl + 1
        end
        crlf && lf
      end

      # The validated {scheme, host, port} to minimize against, or an abort. Split out of
      # cmd_repeater_minimize to keep it under the cyclomatic-complexity bar.
      private def self.minimize_target_or_abort(id : Int64, rec : Store::RepeaterRecord,
                                                text : String, outbound : Gori::Outbound,
                                                verbatim : Bool = false) : {String, String, Int32}
        if Repeater::WsEngine.upgrade_request?(text)
          abort "gori run repeater minimize: session ##{id} is a WebSocket upgrade — minimize works on plain HTTP requests"
        end
        # The TUI refuses this too (repeater_view.cr#minimizable?). A saved request holding
        # §fuzz§ markers is a TEMPLATE, not a request: minimizing it would send 250 requests
        # containing literal § bytes (garbage the origin answers uniformly, which then lets
        # real headers look removable) and --apply would overwrite the user's marked-up
        # template with the mangled result.
        unless Fuzz::Template.marker_regions(text).empty?
          abort "gori run repeater minimize: session ##{id} contains §fuzz§ markers — remove them first, or use `gori run fuzz` to sweep them"
        end
        # Minimize dials `Fuzz::Sender` directly rather than through `Repeater::Plan`, by
        # design, so the builder's unresolved-token refusal (#519) never runs for it and this
        # is the only place that check can happen (#524). Checked BEFORE the target parse: an
        # unresolved `$HOST` survives `Env.expand` as the literal host, which would otherwise
        # surface as an unparseable-target abort naming no variable at all.
        #
        # Head-only on the REQUEST (`unresolved_wire`) for #519's reason — a `$` in a captured
        # body is a byte, and a whole-request check refuses nearly every binary-body session —
        # but whole-string on the target and SNI, which are short operator-typed fields with no
        # body to exclude. The MCP and TUI minimize paths carry the same three checks.
        #
        # Under `--verbatim` the REQUEST drops out of that check, exactly as it does on
        # `repeater send --verbatim`: the operator has said the bytes are the message, so a
        # literal `$user.name` / `$IFS` / OData `$top` is the payload and refusing it makes
        # the flag unable to minimize its own advertised content. The TARGET and SNI are
        # still checked — those are short operator-typed fields that `Env.expand` resolves
        # below either way, and an unresolved `$HOST` there is a dial address, not a payload.
        names = (verbatim ? [] of String : Env.unresolved_wire(text)) |
                Env.unresolved(rec.target) |
                (rec.sni.try { |s| Env.unresolved(s) } || [] of String)
        unless names.empty?
          abort "gori run repeater minimize: " +
                env_unresolved_error(Env.token_list(names), " for session ##{id}")
        end
        scheme, host, port = Repeater::FlowRequest.parse_target(Env.expand(rec.target))
        abort "gori run repeater minimize: could not determine a target host for session ##{id}" if host.empty?
        abort "gori run repeater minimize: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
        target = Gori::Outbound.request_target(text)
        # Layer 1 (include list): the configured project scope, waivable with --allow-unscoped —
        # mirrors fuzz/mine/sequence and MCP minimize's scope_refusal (#406).
        verdict = outbound.check_request(scheme, host, target)
        if verdict.blocked?
          abort "gori run repeater minimize: #{host} is out of the project scope — #{Gori::Outbound.remedy(verdict, "--allow-unscoped")}"
        end
        # Layer 2 (Sandbox / exclude): applies even under --allow-unscoped.
        if reason = outbound.send_block(scheme, host, target)
          abort "gori run repeater minimize: #{reason}"
        end
        {scheme, host, port}
      end

      # `resolve` is the SAME proc the search sent through, so `minimized_request` is the
      # request that was actually tested rather than the pre-resolution source text.
      private def self.report_repeater_minimize(id : Int64, report : Repeater::Minimize::Report,
                                                format : Symbol, applied : Bool,
                                                resolve : Proc(String, Bytes)) : Nil
        wire = resolve.call(report.minimized_text)
        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "repeater_id", id
              j.field "aborted", report.aborted
              j.field "note", report.note
              j.field "sends", report.sends
              j.field("removed") do
                j.array do
                  report.removed.each do |r|
                    j.object { j.field "kind", r.kind.to_s.downcase; j.field "label", r.label }
                  end
                end
              end
              j.field "removed_count", report.removed.size
              j.field "applied", applied && !report.aborted && !report.removed.empty?
              # The RESOLVED wire, plus the source form the session stores, because they are
              # different questions and the operator needs both: the first is what was sent,
              # the second is what `--apply` writes back and what a later send re-resolves.
              # `scrub` for the same reason the repeater's `head` field does it — a minimized
              # request can carry a binary body, and JSON cannot hold an 8-bit octet.
              j.field "minimized_request", String.new(wire).scrub
              unless String.new(wire).valid_encoding?
                j.field "minimized_request_lossy", true
                j.field "minimized_request_base64", Base64.strict_encode(wire)
              end
              j.field "minimized_source", report.minimized_text
            end
          end)
          return
        end
        STDERR.puts "#{report.note} · #{report.sends} send#{report.sends == 1 ? "" : "s"}"
        report.removed.each { |r| STDERR.puts "  - [#{r.kind.to_s.downcase}] #{r.label}" }
        STDERR.puts "saved back to session ##{id}" if applied && !report.aborted && !report.removed.empty?
        STDOUT.write(wire)
        STDOUT.puts unless wire.empty? || wire[-1] == 0x0A_u8
      end
    end
  end
end
