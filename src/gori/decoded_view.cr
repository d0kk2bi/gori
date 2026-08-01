require "json"
require "./saml"
require "./jwt"
require "./graphql"
require "./form_data"

module Gori
  # The single JSON projection of a flow's decoded protocols (SAML / JWT / GraphQL /
  # form params), shared by `gori run show --format json` and MCP `get_flow` so the two
  # surfaces never diverge. The caller passes the heads/bodies to scan (nil-ing a side
  # it wants excluded — e.g. `--request-only`) and an optional `clip` cap (nil = no cap
  # for the CLI; a byte ceiling for an LLM client). Each field is emitted only when the
  # flow carries that protocol.
  module DecodedView
    extend self

    def emit_json(j : JSON::Builder, *, target : String,
                  req_head : Bytes?, req_body : Bytes?,
                  resp_head : Bytes?, resp_body : Bytes?, clip : Int32? = nil) : Nil
      if doc = Saml.from_flow(target, req_head, req_body, resp_head, resp_body)
        j.field "saml" do
          j.object do
            j.field "param", doc.param
            j.field "binding", doc.binding.to_s
            j.field "location", doc.location.to_s
            j.field "relay_state", doc.relay_state
            emit_text(j, "xml", Saml.pretty_xml(doc.xml).scrub, clip)
          end
        end
      end
      jwts = Jwt.from_flow(target, req_head, req_body, resp_head, resp_body)
      unless jwts.empty?
        j.field "jwt" do
          j.array do
            jwts.each do |f|
              j.object do
                j.field "location", f.location
                j.field "token", f.token
                j.field "brief", f.brief
                emit_text(j, "decoded", f.decoded.scrub, clip)
              end
            end
          end
        end
      end
      if op = Graphql.from_flow(target, req_head, req_body)
        j.field "graphql" do
          j.object do
            j.field "operation", op.operation
            # WHICH GraphQL request shape this is (json/query/batch/persisted/multipart/
            # document). A batch's `query` is a rendering of several operations and a
            # persisted query has no document at all, so a reader that assumed one document
            # per request would misread both; `editable` says whether the rendering is a
            # faithful inverse of the bytes (see Graphql::Op#editable?).
            j.field "form", op.form.to_s.downcase
            j.field "editable", op.editable?
            emit_text(j, "query", op.query.scrub, clip)
            j.field "variables", op.variables.try(&.scrub)
            # `form:"invalid"` + why. A GraphQL-carrying request that did not parse used to
            # emit no `graphql` key at all — byte-identical to "this flow is not GraphQL",
            # for the one request most worth looking at.
            j.field "parse_error", op.note if op.note
          end
        end
      end
      if fields = FormData.from_flow(target, req_head, req_body)
        j.field "form_params" do
          j.array do
            fields.each do |f|
              j.object do
                j.field "name", f.name.scrub
                emit_text(j, "value", f.note ? nil : f.value.scrub, clip)
                j.field "source", f.source.to_s
                j.field "note", f.note
              end
            end
          end
        end
      end
    end

    # Emit a (possibly nil) text field, clipped to `clip` bytes when set; a clip flags
    # `<name>_truncated` so the value isn't read as whole.
    private def emit_text(j : JSON::Builder, name : String, text : String?, clip : Int32?) : Nil
      if text.nil?
        j.field name, nil
      elsif clip && text.bytesize > clip
        # clip is a BYTE budget (Serialize::DECODE_TEXT_MAX); compare/cut by bytes and scrub
        # so a cut through a multi-byte UTF-8 sequence can't emit invalid JSON to the client.
        j.field name, text.byte_slice(0, clip).scrub
        j.field "#{name}_truncated", true
      else
        j.field name, text
      end
    end
  end
end
