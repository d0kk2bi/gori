require "../spec_helper"

private alias R = Gori::Repeater

private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

# `Settings` env vars are a process-wide singleton — set, yield, always restore.
private def with_env_vars(pairs : Array({String, String}), &)
  saved_global = Gori::Settings.env_vars
  saved_project = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_vars = pairs
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
  yield
ensure
  Gori::Settings.env_vars = saved_global || [] of {String, String}
  Gori::Settings.project_env_vars = saved_project || [] of {String, String}
  Gori::Settings.env_prefix = saved_prefix || "$"
end

private def wire_of(options : R::PlanOptions) : String
  String.new(R::Plan.build(options, ungated).bytes)
end

# PROVENANCE — `PlanOptions#evidence?`.
#
# The axis behind most of this round's replay defects: draft-time policies (the
# unresolved-`$KEY` refusal, the head's CRLF normalization) exist for a request the operator
# is AUTHORING in a line-buffer editor, and running them on stored evidence changes bytes
# nobody typed. One signal rather than several, because both were off for the same reason and
# the surfaces had already drifted on which of them they remembered to turn off.
describe "Gori::Repeater::PlanOptions#evidence?" do
  describe "the unresolved-$KEY refusal" do
    # OData (`$filter`/`$top`), MongoDB (`$where`), JSONPath, `$IFS` shell probes and
    # `$user.name` SSTI payloads all live in ordinary captured heads. Refusing them made every
    # such capture unreplayable, and the refusal's own remedy ("set the variable") would have
    # SUBSTITUTED a value — i.e. sent a different request than the one captured.
    it "does not fire on evidence" do
      raw = "GET /api?$filter=name%20eq%20x&$top=10 HTTP/1.1\r\nHost: h\r\n" \
            "X-Cmd: ;cat$IFS/etc/passwd\r\nCookie: tmpl=$user.name\r\n\r\n"
      with_env_vars([] of {String, String}) do
        out = wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false, evidence: true))
        out.should eq(raw)
      end
    end

    it "still fires on a DRAFT (the default), naming the tokens" do
      raw = "GET /api?$filter=x HTTP/1.1\r\nHost: h\r\n\r\n"
      with_env_vars([] of {String, String}) do
        ex = expect_raises(R::PlanError) do
          wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h"))
        end
        ex.reason.should eq(R::PlanError::Reason::UnresolvedEnv)
        ex.detail.should eq("$filter")
      end
    end
  end

  describe "the head's CRLF normalization" do
    # A bare-LF header terminator is a front-end/back-end desync primitive gori can already
    # PRODUCE (MCP `verbatim`) and stores byte-exact. Promoting it to CRLF on the way out
    # silently destroys the primitive while still reporting a clean send.
    it "leaves a captured bare-LF head exactly as captured" do
      raw = "POST /lf HTTP/1.1\nHost: h\nContent-Length: 5\n\nhello"
      with_env_vars([] of {String, String}) do
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false, evidence: true)).should eq(raw)
      end
    end

    it "still promotes a DRAFT's bare LFs, which come from the editor's line buffer" do
      raw = "POST /lf HTTP/1.1\nHost: h\nContent-Length: 5\n\nhello"
      with_env_vars([] of {String, String}) do
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false)).should eq("POST /lf HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello")
      end
    end

    # Expansion is a SEPARATE knob: a surface may have merged operator-typed `-H` overrides
    # into the evidence bytes, and those still have to expand.
    it "still expands a resolvable $KEY in evidence bytes, without re-terminating the head" do
      raw = "GET /a HTTP/1.1\nHost: h\nAuthorization: Bearer $TOK\n\n"
      with_env_vars([{"TOK", "s3cr3t"}]) do
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false, evidence: true))
          .should eq("GET /a HTTP/1.1\nHost: h\nAuthorization: Bearer s3cr3t\n\n")
      end
    end
  end
end
