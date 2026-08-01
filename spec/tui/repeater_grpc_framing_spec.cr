require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def grpc_tmp_store(&)
  path = File.tempname("gori-grpcf", ".db")
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

# `Grpc.scan`'s residual — the tail bytes that are NOT a complete frame — is the whole point
# of the change on this branch ("report a framing failure instead of deleting the gRPC view").
# `gori run show --format json` got it; the Repeater pane kept calling `Grpc.messages`, which
# drops the residual, so a deliberately-wrong length prefix (a standard gRPC parser test)
# rendered as a bare "(no complete gRPC messages)" — indistinguishable from "not gRPC".
describe "RepeaterView gRPC framing failure" do
  private_head = "POST /svc/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n"

  def_view = ->(store : Gori::Store) do
    id = store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
      method: "POST", target: "/svc/M", http_version: "HTTP/2",
      head: private_head.to_slice, body: Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41]))
    view = RepeaterView.new
    view.load_grpc(store.get_flow(id).not_nil!)
    view
  end

  resp_head = "HTTP/2 200 OK\r\ncontent-type: application/grpc\r\ngrpc-status: 0\r\n\r\n"

  it "names the byte count when a length prefix claims more than arrived" do
    grpc_tmp_store do |store|
      view = def_view.call(store)
      # prefix claims 9999 bytes; five arrive.
      body = Bytes[0x00, 0x00, 0x00, 0x27, 0x0F, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
      resp = Gori::Proxy::Codec::Http1.parse_response_head(resp_head.to_slice)
      view.apply(Gori::Repeater::Result.new(resp_head.to_slice, body, resp, 5000_i64))

      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("the last 10 bytes are not a complete gRPC frame").should be_true
      backend.contains?("(no complete gRPC messages)").should be_false
    end
  end

  it "still reports a complete message plus its unframed tail" do
    grpc_tmp_store do |store|
      view = def_view.call(store)
      msg = "Hi".to_slice
      io = IO::Memory.new
      io.write(Bytes[0x00, 0x00, 0x00, 0x00, msg.size.to_u8])
      io.write(msg)
      io.write(Bytes[0x00, 0x00]) # 2 leftover bytes — not even a 5-byte prefix
      resp = Gori::Proxy::Codec::Http1.parse_response_head(resp_head.to_slice)
      view.apply(Gori::Repeater::Result.new(resp_head.to_slice, io.to_slice, resp, 5000_i64))

      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("message #1").should be_true
      backend.contains?("the last 2 bytes are not a complete gRPC frame").should be_true
    end
  end

  it "names the REQUEST body's unframed tail instead of just counting 0 messages" do
    grpc_tmp_store do |store|
      # A captured request whose own length prefix over-claims: `→ sent 0 request messages
      # (10b)` used to be the whole story — a byte count and a message count that disagree,
      # with nothing saying why.
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/svc/M", http_version: "HTTP/2",
        head: private_head.to_slice,
        body: Bytes[0x00, 0x00, 0x00, 0x27, 0x0F, 0x68, 0x65, 0x6C, 0x6C, 0x6F]))
      view = RepeaterView.new
      view.load_grpc(store.get_flow(id).not_nil!)
      resp = Gori::Proxy::Codec::Http1.parse_response_head(resp_head.to_slice)
      view.apply(Gori::Repeater::Result.new(resp_head.to_slice, Bytes.empty, resp, 5000_i64))

      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("sent 0 request messages").should be_true
      backend.contains?("the last 10 bytes are not a complete gRPC frame").should be_true
    end
  end

  it "still says nothing framed when the body is genuinely not gRPC-shaped" do
    grpc_tmp_store do |store|
      view = def_view.call(store)
      resp = Gori::Proxy::Codec::Http1.parse_response_head(resp_head.to_slice)
      view.apply(Gori::Repeater::Result.new(resp_head.to_slice, Bytes.empty, resp, 5000_i64))

      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("(no complete gRPC messages)").should be_true
    end
  end
end
