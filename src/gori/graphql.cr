require "json"
require "uri"

module Gori
  # Parses the GraphQL operation a flow carries — a POST JSON body
  # (`{query, operationName?, variables?}`) or a GET `?query=…` — into its operation
  # name, the un-escaped query document, and pretty-printed variables. A DISPLAY-time
  # projection (no table), the request-shaped sibling of `Gori::Sse`. (Pretty already
  # reflows a GraphQL POST body under the `p` toggle; this drives an always-on pane
  # and additionally handles the GET binding Pretty can't see.)
  module Graphql
    extend self

    MAX_BODY = 4 * 1024 * 1024

    # Which of the shapes a real GraphQL API exposes this request is in. Only two of them
    # were ever recognised — a POST JSON object with a `query`, and a GET `?query=` — so a
    # batched array, a persisted query, a multipart upload mutation and a raw
    # `application/graphql` document got NO decoded pane, no variables pretty-print and no
    # projection anywhere, which is precisely the set of shapes that carry the interesting
    # attacks (batching abuse / rate-limit bypass, persisted-query allowlist bypass, upload
    # mutations, content-type confusion).
    #
    # The distinction is not cosmetic: it decides whether the Repeater may RE-ENCODE the
    # request from the edited pane. `display`/`recompose` round-trip an operationName + query
    # + variables triple, which is a faithful inverse for Json and Query and for nothing else
    # — so the other four are projections only. See `editable?`.
    enum Form
      Json      # POST {"query": …}
      Query     # GET ?query=…
      Batch     # POST [{"query": …}, …]
      Persisted # POST {"extensions":{"persistedQuery":{…}}} — no document on the wire
      Multipart # multipart/form-data upload mutation (GraphQL multipart request spec)
      Document  # Content-Type: application/graphql — the body IS the document
      Invalid   # GraphQL-carrying by Content-Type / body shape, but it did not parse
    end

    record Op,
      operation : String?, # operationName
      query : String,      # the GraphQL document (de-escaped)
      variables : String?, # pretty-printed JSON variables, or nil when absent
      form : Form = Form::Json,
      # Why this projection is not the operation (Form::Invalid only). A request that is
      # obviously GraphQL and did not parse must SAY so rather than vanish — reporting it as
      # "not GraphQL" is byte-identical to the answer for an ordinary REST call, and the
      # request most worth looking at is the malformed one. Same treatment gRPC got for a
      # framing failure.
      note : String? = nil do
      # Whether `display(op)` → edit → `recompose` can put the operator's edit back into the
      # exact request it came from. True ONLY for the two shapes that round-trip: a plain
      # POST JSON body and a GET `?query=`.
      #
      # For the rest the display text is a rendering, not an inverse — re-encoding a batch
      # from it would collapse the array into one object, a persisted query has no document
      # to write back, and a multipart/`application/graphql` body is not JSON at all. Sending
      # a request the operator did not write is worse than showing a read-only pane, so the
      # projection exists and the re-encode does not.
      def editable? : Bool
        form.json? || form.query?
      end
    end

    # Parse the operation, or nil if the flow isn't GraphQL. Tries the POST JSON body
    # first, then the GET query string.
    #
    # The query-string fallback is NOT reached for a body-bearing method that actually sent a
    # body: there, the body IS the payload the server reads, so falling through made any
    # `POST /upload?query=%7Bx%7D` with an unrelated (even binary) body report as GraphQL. That
    # is not merely a wrong pane — `location` then answers `:query`, so sending it from the
    # Repeater re-encodes the whole query string, rewriting the operator's request on the
    # strength of a misdetection. A GET carrying a stray body still falls through, which is
    # what the fallback was written for.
    def from_flow(target : String, req_head : Bytes?, req_body : Bytes?) : Op?
      ct = content_type(req_head)
      if (b = req_body) && !b.empty?
        if b.size <= MAX_BODY
          if op = from_body(b, ct)
            return op
          end
        end
        # It did not parse. If the request is GraphQL-CARRYING by its Content-Type or by the
        # shape of its body, report the failure instead of deleting the view.
        if reason = unparsed_reason(b, ct)
          return Op.new(nil, "", nil, Form::Invalid, reason)
        end
      end
      return nil if (b = req_body) && !b.empty? && body_bearing?(req_head)
      from_query(target)
    end

    # A body that opens as a GraphQL envelope: `{"query":` or a batch's `[{"query":`, with the
    # whitespace either side that a pretty-printed client emits. Anchored, and only the first
    # bytes are examined, so an ordinary JSON body that merely CONTAINS the word never matches.
    ENVELOPE_RE = /\A\s*\[?\s*\{\s*"query"\s*:/

    # Why a GraphQL-carrying request did not parse, or nil when it is not GraphQL-carrying at
    # all (an ordinary REST body, which must keep getting no GraphQL section).
    #
    # Deliberately narrow: a Content-Type the GraphQL-over-HTTP spec defines, or a body that
    # opens as the envelope. A `multipart/form-data` POST is NOT enough on its own — that is
    # every ordinary file upload — so it qualifies only once its `operations` part is present.
    private def unparsed_reason(body : Bytes, content_type : String?) : String?
      folded = (content_type || "").downcase
      over = body.size > MAX_BODY
      if folded.starts_with?("application/graphql")
        return over ? too_big : "Content-Type is application/graphql but the body carries no selection set"
      end
      if folded.starts_with?("multipart/form-data")
        boundary = multipart_boundary(content_type || "") || return nil
        return nil unless multipart_part(body, boundary, "operations")
        return over ? too_big : "the multipart `operations` part is not a valid GraphQL envelope"
      end
      head = String.new(body[0, {body.size, 256}.min]).scrub
      return nil unless ENVELOPE_RE.matches?(head.lchop('\u{FEFF}'))
      return too_big if over
      # It opens as an envelope — but "opens like one" is not "is one". A body that PARSES as
      # JSON and was still rejected is an ordinary REST call carrying a string `query` field
      # (`{"query":"shoes","page":2}`), which must keep getting no GraphQL section at all;
      # only a body that does not parse is the truncated/mangled envelope worth reporting.
      return nil if json?(String.new(body))
      "the body opens as a GraphQL envelope but is not valid JSON"
    end

    private def too_big : String
      "the body is larger than the #{MAX_BODY // (1024 * 1024)} MiB decode ceiling — " \
      "it may also have been cut at the capture cap"
    end

    # The request BODY's GraphQL projection, dispatched on Content-Type. The body used to be
    # JSON-parsed unconditionally, which is why `application/graphql` (a raw document, the
    # GraphQL-over-HTTP spec's other request form) and a multipart upload mutation could
    # never be GraphQL: neither body is JSON.
    def from_body(body : Bytes, content_type : String?) : Op?
      ct = content_type || ""
      # The MEDIA TYPE is case-insensitive; a PARAMETER value is not — `boundary=----X` and
      # `boundary=----x` delimit different bodies, so only the type is folded for the match
      # and `from_multipart` gets the original spelling.
      folded = ct.downcase
      return from_document(String.new(body)) if folded.starts_with?("application/graphql")
      return from_multipart(body, ct) if folded.starts_with?("multipart/form-data")
      from_json(String.new(body))
    end

    # The `Content-Type` header VALUE off a request head (media type + parameters), or nil.
    # `from_flow` has always been handed the head and, before the shapes above, never had a
    # reason to look at it.
    private def content_type(req_head : Bytes?) : String?
      head = req_head || return nil
      String.new(head).each_line do |raw|
        line = raw.chomp
        break if line.empty? # the blank line ends the head
        idx = line.index(':') || next
        return line[(idx + 1)..].strip if line[0...idx].strip.compare("content-type", case_insensitive: true) == 0
      end
      nil
    end

    # `Content-Type: application/graphql` — the body IS the document, no JSON envelope
    # (GraphQL-over-HTTP). The `{` test is the same selection-set check the JSON path uses.
    private def from_document(body : String) : Op?
      doc = strip(body)
      return nil unless doc.includes?('{')
      Op.new(nil, doc, nil, Form::Document)
    end

    # A GraphQL multipart request (the `operations`/`map`/`0…` upload convention): the
    # `operations` part carries the ordinary JSON envelope, so parse that and keep the form
    # so nothing tries to re-encode the multipart body from the pane.
    private def from_multipart(body : Bytes, content_type : String) : Op?
      boundary = multipart_boundary(content_type) || return nil
      ops = multipart_part(body, boundary, "operations") || return nil
      op = from_json(ops) || return nil
      Op.new(op.operation, op.query, op.variables, Form::Multipart)
    end

    # `boundary=…` off a multipart Content-Type, quoted or bare. The parameter NAME is
    # case-insensitive; its VALUE is not (`----X` and `----x` delimit different bodies).
    BOUNDARY_RE = /boundary\s*=\s*(?:"([^"]*)"|([^;\s]+))/i

    private def multipart_boundary(content_type : String) : String?
      m = BOUNDARY_RE.match(content_type) || return nil
      v = m[1]? || m[2]? || return nil
      v.empty? ? nil : v
    end

    # The body of the multipart part named `name`, as text. Deliberately minimal: only the
    # `operations` part is read, and only to hand its JSON to the ordinary parser.
    private def multipart_part(body : Bytes, boundary : String, name : String) : String?
      text = String.new(body)
      needle = "name=\"#{name}\""
      text.split("--#{boundary}") do |part|
        next unless part.includes?(needle)
        sep = part.index("\r\n\r\n") || part.index("\n\n") || next
        skip = part[sep, 2] == "\r\n" ? 4 : 2
        return part[(sep + skip)..].rstrip("\r\n")
      end
      nil
    end

    # Whether the request line names a method whose BODY carries the payload. Read off the
    # head, which `from_flow` has always been handed and never looked at. nil (no head, as in
    # a unit call) keeps the permissive fallback.
    private def body_bearing?(req_head : Bytes?) : Bool
      head = req_head || return false
      line = String.new(head[0, {head.size, 64}.min])
      sp = line.index(' ') || return false
      case line[0, sp].upcase
      when "POST", "PUT", "PATCH" then true
      else                             false
      end
    end

    # A POST JSON body. A GraphQL document always has a selection set, so requiring a
    # `{` in the query string avoids hijacking an ordinary REST body that happens to
    # carry a string `query` field (e.g. `{"query":"shoes"}`).
    #
    # A top-level ARRAY is a batched request — the shape a batching-abuse / rate-limit-bypass
    # test uses — and an object with no `query` but an `extensions.persistedQuery` is a
    # persisted query, which by definition sends no document at all. `json.as_h?` used to
    # reject the first and the `query` requirement the second, so neither was ever GraphQL.
    def from_json(body : String) : Op?
      json = JSON.parse(strip(body))
      if arr = json.as_a?
        return from_batch(arr)
      end
      h = json.as_h? || return nil
      single_op(h)
    rescue
      nil
    end

    # One JSON envelope object → its op. Returns nil for an object that is neither a
    # document-bearing request nor a persisted query.
    private def single_op(h : Hash(String, JSON::Any)) : Op?
      vars = h["variables"]?
      vars_text = (vars && !vars.raw.nil?) ? vars.to_pretty_json : nil
      name = h["operationName"]?.try(&.as_s?)
      if (q = h["query"]?.try(&.as_s?)) && q.includes?('{')
        return Op.new(name, q.strip, vars_text)
      end
      # No document. A `persistedQuery` extension says so explicitly — the server resolves
      # the hash to a stored document — and nothing else in the wild carries that key, so it
      # is a safe positive where a bare `{"variables":…}` would not be.
      pq = h["extensions"]?.try(&.as_h?).try(&.["persistedQuery"]?).try(&.as_h?) || return nil
      Op.new(name, persisted_text(pq), vars_text, Form::Persisted)
    end

    # The read-only rendering of a persisted query: there is no document on the wire, so the
    # pane shows what WAS sent — the version and the hash the server will look up.
    private def persisted_text(pq : Hash(String, JSON::Any)) : String
      String.build do |io|
        io << "# persisted query — no document was sent"
        pq.each do |k, v|
          io << "\n# " << k << ": " << (v.as_s? || v.to_json)
        end
      end
    end

    # A batched request. Every element must be an object that is itself an op — one stray
    # element and this is not a GraphQL batch, and guessing would hijack an ordinary JSON
    # array body.
    private def from_batch(arr : Array(JSON::Any)) : Op?
      return nil if arr.empty?
      ops = [] of Op
      arr.each do |item|
        h = item.as_h? || return nil
        ops << (single_op(h) || return nil)
      end
      Op.new(nil, batch_text(ops), nil, Form::Batch)
    end

    # The read-only rendering of a batch: each operation in order, under its index, so the
    # operator can see how many calls one request carries and what each of them asks for.
    private def batch_text(ops : Array(Op)) : String
      String.build do |io|
        io << "# batch of " << ops.size << " operation" << (ops.size == 1 ? "" : "s")
        ops.each_with_index do |op, i|
          io << "\n\n# --- [" << i << "] ---\n" << display(op)
        end
      end
    end

    # A GET `?query=…&operationName=…&variables=…` request.
    def from_query(target : String) : Op?
      idx = target.index('?') || return nil
      params = {} of String => String
      target[(idx + 1)..].split('&').each do |pair|
        k, sep, v = pair.partition('=')
        params[k] = (URI.decode_www_form(v) rescue v) unless sep.empty?
      end
      q = params["query"]? || return nil
      return nil unless q.includes?('{')
      vars = params["variables"]?.try { |v| (JSON.parse(v).to_pretty_json rescue v) }
      Op.new(params["operationName"]?, q.strip, vars, Form::Query)
    rescue
      nil
    end

    # The display text for a parsed op: an operationName header, the query, and the
    # variables block (each present only when set). This is the editable form shown in
    # the Repeater DECODED pane; parse_display is its inverse.
    def display(op : Op) : String
      # A failed parse has no document to show, so the pane shows WHY. Rendered here rather
      # than at each of the five call sites (History detail, the Fuzzer pane, `gori run show`,
      # `get_flow`, the Repeater's read-only view) so none of them can render an empty box.
      return "# GraphQL parse failed: #{op.note}" if op.form.invalid?
      String.build do |io|
        if name = op.operation
          io << "# operationName: " << name << "\n\n"
        end
        io << op.query
        if v = op.variables
          io << "\n\n# variables\n" << v
        end
      end
    end

    # Parse the editable DECODED-pane text back into {operationName?, query, variables?}.
    # The variables block is whatever follows the LAST *genuine* `# variables` line; an
    # optional leading `# operationName:` header is lifted off; the rest is the query.
    #
    # `# variables` is ALSO a valid GraphQL source comment, so a comment line inside the
    # query could masquerade as the sentinel and truncate the query. Disambiguate on the
    # trailing block: the real sentinel is always followed by the variables JSON, whereas a
    # query comment is followed by more GraphQL — so only accept a `# variables` whose
    # remainder parses as JSON. This keeps an in-query `# variables` comment in the query.
    def parse_display(text : String) : {String?, String, String?}
      lines = text.split('\n')
      vi = nil.as(Int32?)
      # Scan BACKWARD for the last "# variables" whose remainder parses as JSON, breaking on the
      # first (from-end) match, and only attempt the parse when the trailing plausibly starts
      # with '{'/'[' — a forward re-join+parse per candidate is O(n²) on a query full of literal
      # "# variables" comment lines. `rev` holds the trailing lines in reverse (cheap push).
      rev = [] of String
      tail_first = nil.as(Char?) # first non-blank char of the accumulated trailing
      (lines.size - 1).downto(0) do |i|
        line = lines[i]
        if line.strip == "# variables" && (tail_first == '{' || tail_first == '[')
          trailing = rev.reverse.join('\n').strip
          if !trailing.empty? && json?(trailing)
            vi = i
            break
          end
        end
        rev << line
        if fnb = line.each_char.find { |c| !c.whitespace? }
          tail_first = fnb # a non-blank line becomes the new first-non-blank of the trailing
        end
      end
      vars = vi ? lines[(vi + 1)..].join('\n').strip : nil
      body = vi ? lines[0...vi] : lines
      op = nil.as(String?)
      first = body.index { |l| !l.strip.empty? }
      if first && body[first].strip.starts_with?("# operationName:") && blank_after?(body, first)
        op = body[first].strip.lchop("# operationName:").strip
        body = body[0...first] + body[(first + 1)..]
      end
      {op.try { |o| o.empty? ? nil : o }, body.join('\n').strip, (vars && !vars.empty?) ? vars : nil}
    end

    # Re-encode the edited DECODED pane back into a JSON request body, overlaying the
    # operationName/query/variables onto the ORIGINAL body so any other fields (e.g. a
    # persisted-query `extensions`) survive. Invalid edited variables fall back to the
    # original. Returns minified JSON (wire form).
    def recompose(envelope_body : String, decoded_text : String) : String
      op, query, vars_text = parse_display(decoded_text)
      base = (JSON.parse(strip(envelope_body)).as_h? rescue nil)
      obj = {} of String => JSON::Any
      obj["operationName"] = JSON::Any.new(op) if op
      obj["query"] = JSON::Any.new(query)
      base_vars = base.try(&.["variables"]?)
      if vars_text
        obj["variables"] = (JSON.parse(vars_text) rescue base_vars || JSON::Any.new(vars_text))
      elsif base_vars
        obj["variables"] = base_vars
      end
      # Keep extensions etc. — but NOT `operationName`: the pane always renders it when it is
      # set, so an operator who deleted the header meant to unset it, and overlaying the base
      # back silently ignored the deletion. Absence here is a decision, not "unchanged".
      base.try &.each { |k, v| obj[k] = v unless obj.has_key?(k) || k == "operationName" }
      obj.to_json
    end

    # Re-encode the edited DECODED pane back into a GET request's query string, overlaying
    # query/operationName/variables onto the ORIGINAL params (any other params survive).
    # Variables are minified. The GET-binding sibling of recompose (which targets the body).
    def recompose_query(orig_query : String, decoded_text : String) : String
      op, query, vars_text = parse_display(decoded_text)
      mini = vars_text.try { |v| (JSON.parse(v).to_json rescue v) }
      replacement = {
        "query"         => "query=#{URI.encode_www_form(query)}",
        "operationName" => op.try { |o| "operationName=#{URI.encode_www_form(o)}" },
        "variables"     => mini.try { |m| "variables=#{URI.encode_www_form(m)}" },
      }
      # Replace the managed params IN PLACE rather than dropping them and appending. Rejecting
      # and re-adding moved them to the end, so `page=2&query=…&sig=abc` came back as
      # `page=2&sig=abc&query=…` — a request the operator did not write, and one that breaks any
      # signature or cache key computed over the canonical query string. Unmanaged params keep
      # their positions and their exact spelling either way.
      seen = Set(String).new
      parts = [] of String
      orig_query.split('&').each do |pair|
        next if pair.empty?
        key = pair.partition('=')[0]
        unless replacement.has_key?(key)
          parts << pair
          next
        end
        next unless seen.add?(key)              # a repeated managed param collapses into the first
        replacement[key].try { |r| parts << r } # nil = the edit removed it
      end
      replacement.each { |k, r| parts << r if r && seen.add?(k) } # not in the original: append
      parts.join('&')
    end

    # Where a flow carries its op: :body (a POST JSON body that parses as GraphQL), :query
    # (a GET `?query=…`), or :none. Drives which side the Repeater re-encode targets.
    #
    # `:none` is the answer for every shape `display` renders but `recompose` cannot invert
    # (batch, persisted, multipart, raw document — see `Op#editable?`). It has to exist:
    # once those shapes parse as GraphQL, answering `:body` would recompose a batch array
    # into a single object and answering `:query` would rewrite the query STRING of a request
    # whose payload is in the body. Either one sends a request the operator never wrote, on
    # the strength of a projection.
    def location(req_body : Bytes?, req_head : Bytes? = nil) : Symbol
      op = ((b = req_body) && !b.empty? && b.size <= MAX_BODY) ? from_body(b, content_type(req_head)) : nil
      return :query unless op # no body op at all — the GET `?query=` binding
      op.editable? ? :body : :none
    end

    # `# operationName:` is ALSO a valid GraphQL source comment, so the same disambiguation the
    # `# variables` sentinel already gets is owed to this one — without it a document whose
    # FIRST line is a comment starting with those characters had that line deleted from the
    # query and its text promoted into a real `operationName` field, changing which operation
    # the server runs. `display` always writes the header as `"# operationName: NAME\n\n"`
    # (`display` above), so the genuine sentinel is followed by a BLANK line; a comment that
    # opens a document is followed by more GraphQL.
    private def blank_after?(lines : Array(String), i : Int32) : Bool
      nxt = lines[i + 1]?
      nxt.nil? || nxt.strip.empty?
    end

    private def json?(s : String) : Bool
      JSON.parse(s)
      true
    rescue
      false
    end

    private def strip(s : String) : String
      s.lchop('\u{FEFF}').strip
    end
  end
end
