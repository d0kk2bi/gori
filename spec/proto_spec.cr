require "./spec_helper"

describe Gori::Proto do
  describe ".classify" do
    it "classifies a 101 upgrade as WebSocket (status wins over any type)" do
      Gori::Proto.classify(101, nil).should eq(Gori::Proto::Kind::Ws)
      Gori::Proto.classify(101, "application/grpc").should eq(Gori::Proto::Kind::Ws)
    end

    it "classifies gRPC by Content-Type, including +proto and grpc-web variants" do
      Gori::Proto.classify(200, "application/grpc").should eq(Gori::Proto::Kind::Grpc)
      Gori::Proto.classify(200, "application/grpc+proto").should eq(Gori::Proto::Kind::Grpc)
      Gori::Proto.classify(200, "application/grpc-web+proto").should eq(Gori::Proto::Kind::Grpc)
      Gori::Proto.classify(200, "APPLICATION/GRPC").should eq(Gori::Proto::Kind::Grpc)
    end

    it "classifies SSE by Content-Type, tolerating charset params" do
      Gori::Proto.classify(200, "text/event-stream").should eq(Gori::Proto::Kind::Sse)
      Gori::Proto.classify(200, "text/event-stream; charset=utf-8").should eq(Gori::Proto::Kind::Sse)
    end

    it "treats everything else — including a pending/typeless flow — as HTTP" do
      Gori::Proto.classify(200, "text/html").should eq(Gori::Proto::Kind::Http)
      Gori::Proto.classify(nil, nil).should eq(Gori::Proto::Kind::Http)
      Gori::Proto.classify(200, nil).should eq(Gori::Proto::Kind::Http)
    end
  end

  describe Gori::Proto::Kind do
    # The tag used to REPLACE the scheme for WS/GRPC/SSE, so a `ws://` row and a `wss://` row
    # were pixel-identical in History — same METHOD, same PROTO, same HOST (the column carries
    # no port) — for exactly the three protocols where "the app opened a CLEARTEXT WebSocket
    # and put a session token in the first frame" is the finding. The Http member kept the
    # HTTP/HTTPS pair the whole time; the others now carry the same signal the same way.
    it "labels the transport as well as the protocol, for every member" do
      Gori::Proto::Kind::Http.label("http").should eq("HTTP")
      Gori::Proto::Kind::Http.label("https").should eq("HTTPS")
      Gori::Proto::Kind::Ws.label("http").should eq("WS")
      Gori::Proto::Kind::Ws.label("https").should eq("WSS")
      Gori::Proto::Kind::Grpc.label("http").should eq("GRPC")
      Gori::Proto::Kind::Grpc.label("https").should eq("GRPCS")
      Gori::Proto::Kind::Sse.label("http").should eq("SSE")
      Gori::Proto::Kind::Sse.label("https").should eq("SSES")
    end

    # A WebSocket flow is stored with the HTTP scheme of the tunnel it ran in, so `https` is
    # what a `wss://` row actually carries; `wss` is accepted for a caller holding a URL.
    it "reads the transport off a flow's stored scheme" do
      Gori::Proto.secure?("https").should be_true
      Gori::Proto.secure?("wss").should be_true
      Gori::Proto.secure?("http").should be_false
      Gori::Proto.secure?("ws").should be_false
      Gori::Proto.secure?("").should be_false
    end

    # Every string `label` can print has to be a value the `proto:` filter accepts, or the
    # column and the QL drift — which is the invariant the module doc claims.
    it "splits the transport spelling the PROTO column prints off the protocol" do
      Gori::Proto.split_transport("wss").should eq({"ws", true})
      Gori::Proto.split_transport("grpcs").should eq({"grpc", true})
      Gori::Proto.split_transport("sses").should eq({"sse", true})
      Gori::Proto.split_transport("HTTPS").should eq({"http", true})
      # No transport named — "either", not "cleartext".
      Gori::Proto.split_transport("ws").should eq({"ws", nil})
      Gori::Proto.split_transport("websocket").should eq({"websocket", nil})
      Gori::Proto.split_transport("nope").should eq({"nope", nil})
    end

    # `Kind.parse?` deliberately does NOT absorb the TLS spellings: `InterceptFilter.fold`
    # canonicalizes through it, has one field per leaf, and cannot carry a transport term —
    # folding `wss` to `ws` there would silently widen an operator's catch condition to
    # cleartext sockets.
    it "parses QL proto: values (websocket is an alias for ws) and rejects unknowns" do
      Gori::Proto::Kind.parse?("ws").should eq(Gori::Proto::Kind::Ws)
      Gori::Proto::Kind.parse?("websocket").should eq(Gori::Proto::Kind::Ws)
      Gori::Proto::Kind.parse?("GRPC").should eq(Gori::Proto::Kind::Grpc)
      Gori::Proto::Kind.parse?("http").should eq(Gori::Proto::Kind::Http)
      Gori::Proto::Kind.parse?("nope").should be_nil
      Gori::Proto::Kind.parse?("wss").should be_nil
    end
  end
end
