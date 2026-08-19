require "../spec_helper"

# `Fuzz::HistoryRecord` — the opt-in `--record-history` write that turns a fuzz result into a
# History flow (#749). The projection mirrors MCP's own recorder; this pins the shared engine
# half plus the `records?` policy.
private def with_store(&)
  path = File.tempname("gori-fuzzhist", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def result_with(request : String?, resp_head : String, *, matched : Bool) : Gori::Fuzz::Result
  Gori::Fuzz::Result.new(
    index: 0_i64, payloads: ["p"], position: nil, status: 200, length: 2_i64, words: 1, lines: 1,
    duration_us: 10_i64, error: nil, matched: matched, incomplete: false, retried: false,
    extracted: nil, head: resp_head.to_slice, body: "ok".to_slice,
    request: request.try(&.to_slice))
end

describe Gori::Fuzz::HistoryRecord do
  describe ".records?" do
    it ":none records nothing, :all records every result, :matched records only matches" do
      m = result_with("GET / HTTP/1.1\r\n\r\n", "HTTP/1.1 200 OK\r\n\r\n", matched: true)
      u = result_with("GET / HTTP/1.1\r\n\r\n", "HTTP/1.1 404 NF\r\n\r\n", matched: false)
      Gori::Fuzz::HistoryRecord.records?(:none, m).should be_false
      Gori::Fuzz::HistoryRecord.records?(:all, u).should be_true
      Gori::Fuzz::HistoryRecord.records?(:matched, m).should be_true
      Gori::Fuzz::HistoryRecord.records?(:matched, u).should be_false
    end
  end

  describe ".record" do
    it "writes the rendered request + response as one flow" do
      with_store do |store|
        r = result_with("GET /hit?q=1 HTTP/1.1\r\nHost: t.test\r\n\r\n",
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n", matched: true)
        id = Gori::Fuzz::HistoryRecord.record(store, r, scheme: "https", host: "t.test", port: 443, http2: false).not_nil!
        detail = store.get_flow(id).not_nil!
        detail.row.method.should eq("GET")
        detail.row.target.should eq("/hit?q=1")
        detail.row.host.should eq("t.test")
        detail.row.status.should eq(200)
      end
    end

    it "returns nil when the result kept no request bytes (keep_bodies was :none)" do
      with_store do |store|
        r = result_with(nil, "HTTP/1.1 200 OK\r\n\r\n", matched: true)
        Gori::Fuzz::HistoryRecord.record(store, r, scheme: "http", host: "t.test", port: 80, http2: false).should be_nil
      end
    end
  end
end
