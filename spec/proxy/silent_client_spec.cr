require "../spec_helper"
require "socket"

# #755, half one: a client that opens a connection, sends ZERO bytes and times out is on the
# record instead of nowhere — and, just as importantly, an ordinary idle keep-alive still is not.
#
# Driven through a stub client IO rather than a real socket, for one reason: the wait is
# `SocketTuning::CLIENT_IO_TIMEOUT`, a 30 s constant `ClientConn#run` re-arms at the top of every
# keep-alive iteration, so a real socket cannot be made to time out sooner from outside. What the
# stub stands in for — that a real socket's zero-byte timeout arrives as a `HeadTimeout` whose
# `received` is 0 — is pinned separately and against real sockets in
# `spec/proxy/socket_tuning_spec.cr`. The UPSTREAM leg here is a real origin.
#
# The one link neither half can assert directly is that a stalled read on a DECRYPTED socket
# surfaces as `IO::TimeoutError` and not an OpenSSL error — i.e. that this reaches the real
# SMTPS-through-a-tunnel case. `tls/tunnel.cr`'s `close_client_transport` comment records that
# observation for the handshake read one layer down, on the same socket type.
#
# What the stub does NOT stand in for is the exception: it raises the plain `IO::TimeoutError` a
# socket raises and lets `read_head` convert, so the count the fix branches on is measured, not
# supplied. The deadlined path's own conversion is pinned on real sockets in
# `spec/proxy/socket_tuning_spec.cr`.

private class RecSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses = [] of Gori::Store::CapturedResponse

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @requests.size.to_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# A client leg that plays `script` back byte-by-byte and then times out exactly as a real socket
# does once the head read runs out of clock.
#
# It raises the PLAIN `IO::TimeoutError` a socket read raises, NOT the `HeadTimeout` the fix keys
# on — so the conversion (and therefore its byte count) is gori's own code under test rather than
# something the stub fabricated. `read_head` converts on both of its paths for exactly this
# reason; see the rescue in `read_head`.
private class TimingOutClient < IO
  getter written = IO::Memory.new

  def initialize(script : String = "")
    @script = IO::Memory.new(script)
  end

  def read(slice : Bytes) : Int32
    n = @script.read(slice)
    return n if n > 0
    raise IO::TimeoutError.new("simulated client read timeout")
  end

  def write(slice : Bytes) : Nil
    @written.write(slice)
  end
end

private def serve_one(conn : TCPSocket, body : String) : Nil
  while head = Gori::Proxy::Codec::Http1.read_head(conn)
    break if head.empty?
    conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
    conn.flush
  end
rescue
ensure
  conn.close rescue nil
end

private def start_origin(body : String) : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      spawn serve_one(conn, body)
    end
  end
  port
end

describe "a client that connects and says nothing" do
  it "records a visible flow naming server-speaks-first and the TLS remedy (#755)" do
    sink = RecSink.new
    Gori::Proxy::ClientConn.new(TimingOutClient.new, "https", sink,
      fixed_host: "mail.acme.test", fixed_port: 993,
      h2_offer: Gori::Proxy::H2Offer::Cleartext, client_tls: true).run

    sink.requests.size.should eq(1)
    sink.responses.size.should eq(1)
    # Inside a tunnel the columns DO name the origin the client asked for, unlike the cleartext
    # listener's all-empty row.
    sink.requests.first.host.should eq("mail.acme.test")
    sink.requests.first.port.should eq(993)

    resp = sink.responses.first
    resp.state.should eq(Gori::Store::FlowState::Error)
    msg = resp.error.not_nil!
    msg.should contain("sent zero bytes")
    msg.should contain("SERVER-SPEAKS-FIRST")
    # The remedy, worded for a connection whose TLS gori terminated — `client_tls: true` above.
    msg.should contain("gori terminated TLS on this connection")
    msg.should contain("network.tls_passthrough")
    msg.should contain("\"mail.acme.test\"") # named, not "this host"
    # The one innocent shape that also lands here, said out loud rather than filtered out.
    msg.should contain("preconnect")
  end

  # The cleartext listener wording — the other half of the discriminator #755 fixed. `@tls` used
  # to decide this and got it exactly backwards, and both existing #729 examples run without a
  # `tls:` so neither could see it.
  it "words the remedy for a cleartext listener when gori terminated no TLS" do
    sink = RecSink.new
    Gori::Proxy::ClientConn.new(TimingOutClient.new, "http", sink,
      h2_offer: Gori::Proxy::H2Offer::Cleartext, client_tls: false).run

    msg = sink.responses.first.error.not_nil!
    msg.should contain("this listener expects HTTP")
    msg.should_not contain("gori terminated TLS")
  end

  # THE CONTROL, and the noise bound the issue asks for: the same zero-byte timeout on a
  # connection that already carried a request is an idle keep-alive reaching its end, which is
  # how a healthy connection dies. Exactly one flow, and it is the GET.
  it "records nothing extra when an idle keep-alive connection times out after serving a request" do
    origin_port = start_origin("ok")
    sink = RecSink.new
    client = TimingOutClient.new("GET /served HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n")
    Gori::Proxy::ClientConn.new(client, "http", sink,
      h2_offer: Gori::Proxy::H2Offer::Cleartext, client_tls: false).run

    sink.responses.size.should eq(1)
    sink.responses.first.state.should eq(Gori::Store::FlowState::Complete)
    sink.requests.first.target.should eq("/served")
    sink.responses.first.error.should be_nil
    String.new(client.written.to_slice).should contain("200 OK") # the request really was served
  end
end

# Test seam, in the `Gori::CLI::Run.spec_oast_wait_or_stop` shape: `peek_first` /
# `peek_transparent_first` are private and the wait they answer is
# `SocketTuning::CLIENT_IO_TIMEOUT`, a 30 s constant `Server#serve_connection` arms on the
# accepted socket. Exposing a thin caller (test binary only) lets the spec arm 100 ms itself,
# so the record on a silent peer is pinned without a 30-second example.
class Gori::Proxy::Server
  def spec_peek_first(client : TCPSocket, scheme : String, host : String, port : Int32) : Bytes?
    peek_first(client, scheme, host, port)
  end

  def spec_peek_transparent_first(client : TCPSocket) : Bytes?
    peek_transparent_first(client)
  end
end

# The listener half of the same signal. `Server#serve_reverse` and `#serve_transparent` route on
# `client.peek` BEFORE any ClientConn exists, so the fix above could not reach them — and they are
# the only two listeners a plaintext server-speaks-first protocol can arrive on, since SMTP/IMAP
# cannot traverse a forward proxy without a CONNECT.
# Accept one connection, arm a short read timeout on the SERVER side (standing in for
# CLIENT_IO_TIMEOUT), and hand it to the seam. Yields the accepted socket.
private def with_silent_peer(&)
  listener = TCPServer.new("127.0.0.1", 0)
  begin
    client = TCPSocket.new("127.0.0.1", listener.local_address.port)
    accepted = listener.accept
    accepted.read_timeout = 100.milliseconds # what serve_connection arms, only shorter
    begin
      yield accepted
    ensure
      accepted.close rescue nil
      client.close rescue nil
    end
  ensure
    listener.close rescue nil
  end
end

describe "a listener whose client says nothing before the first-byte peek" do
  it "records the DECLARED origin on a reverse listener, and still re-raises (#755)" do
    sink = RecSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    with_silent_peer do |accepted|
      # Re-raised on purpose: the accept path's own rescue is what closes the fd and frees the
      # connection slot, and #755 changed only the silence, not the teardown.
      expect_raises(IO::TimeoutError) do
        proxy.spec_peek_first(accepted, "http", "mail.acme.test", 25)
      end
    end

    sink.responses.size.should eq(1)
    sink.requests.first.host.should eq("mail.acme.test") # the row names what it was dialling
    sink.requests.first.port.should eq(25)
    msg = sink.responses.first.error.not_nil!
    msg.should contain("sent zero bytes")
    msg.should contain("SERVER-SPEAKS-FIRST")
    msg.should contain("this listener expects HTTP") # no TLS was terminated: nothing arrived
  end

  it "records on a transparent listener, naming the kernel's destination when it has one" do
    sink = RecSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    with_silent_peer do |accepted|
      expect_raises(IO::TimeoutError) { proxy.spec_peek_transparent_first(accepted) }
    end

    sink.responses.size.should eq(1)
    sink.responses.first.error.not_nil!.should contain("sent zero bytes")
    # A loopback pair carries no SO_ORIGINAL_DST, so the kernel has no answer here and the row
    # falls back to the listener's target port with no host — the honest outcome, and the reason
    # the docs promise a name only where the platform provides one.
    sink.requests.first.port.should eq(80)
  end
end
