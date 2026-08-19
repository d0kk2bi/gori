require "./types"
require "../flow_mapper"
require "../env"
require "../proxy/codec/http1"

module Gori
  module Fuzz
    # Records a fuzz RESULT as a History flow — the opt-in evidence half of `record_history`
    # (`none | matched | all`). Shared engine logic so `gori run fuzz --record-history` and MCP
    # `fuzz_start.record_history` project the same request/response the same way.
    #
    # A `Fuzz::Result` only carries its rendered `request` / `body` bytes when the matcher was
    # built with `keep_bodies` other than `:none` (retention is the axis) — a caller that wants
    # to record MUST build the engine with the matching policy, or `request` is nil here and
    # nothing is written.
    module HistoryRecord
      extend self

      # Cap on flows written per run, so `record_history: all` on a huge sweep cannot grow the
      # DB without bound. Shared with MCP's own recorder.
      MAX = 5_000

      # Record `r`'s rendered request + response as one flow and return the new id, or nil when
      # there is nothing to record (no retained request bytes) or the write did not commit.
      # Never raises: recording must not break a sweep — a failure just yields nil.
      def record(store : Store, r : Result, *, scheme : String, host : String, port : Int32,
                 http2 : Bool) : Int64?
        request = r.request
        return nil unless request
        head, body = split_head_body(request)
        method, target, version = Proxy::Codec::Http1.authored_start_line(head)
        fid = store.insert_flow(Store::CapturedRequest.new(
          created_at: Time.utc.to_unix_ms * 1000_i64,
          scheme: scheme, host: host, port: port,
          method: method, target: target,
          http_version: http2 ? "HTTP/2" : version,
          head: head, body: body, body_size: body.try(&.size.to_i64)))
        return nil if fid <= 0
        rhead = r.head
        if rhead && !rhead.empty? && (resp = (Proxy::Codec::Http1.parse_response_head(rhead) rescue nil))
          store.update_response(FlowMapper.response(resp, flow_id: fid, body: r.body,
            duration_us: r.duration_us,
            state: r.error ? Store::FlowState::Error : Store::FlowState::Complete,
            error: r.error, body_size: r.body.try(&.size.to_i64)))
        else
          store.update_response(FlowMapper.error_response(fid, r.error || "no response recorded"))
        end
        fid
      rescue
        nil
      end

      # Whether `policy` (:none | :matched | :all) records this result. `all` records every sent
      # request; `matched` only the ones the matcher kept; `none` records nothing.
      def records?(policy : Symbol, r : Result) : Bool
        return false if policy == :none
        policy == :all || r.matched?
      end

      private def split_head_body(bytes : Bytes) : {Bytes, Bytes?}
        boundary = Env.head_body_boundary(bytes)
        head = bytes[0, boundary]
        body_size = bytes.size - boundary
        {head, body_size > 0 ? bytes[boundary, body_size] : nil}
      end
    end
  end
end
