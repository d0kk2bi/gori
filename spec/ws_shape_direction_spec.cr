require "./spec_helper"

# RFC 6455 §5.1 fixes masking per direction: a client→server frame MUST be masked, a
# server→client frame MUST NOT be. The repeater transcript reused the outbound message
# model to render BOTH directions, so it stamped "unmasked" on every inbound server frame —
# firing the §5.1 marker on the ordinary case and burying the anomaly it exists for. It also
# made `Shape#default?` false for every inbound frame, so the plain `← ABCD` transcript line
# was unreachable and every server frame rendered as `← [TEXT unmasked] ABCD`.
private alias Shape = Gori::Proxy::WS::Shape
private alias Msg = Gori::Store::WsOutMessage

describe "WebSocket frame shape, per direction" do
  describe "Shape#default?(to_server)" do
    it "treats an unmasked server→client frame as ordinary" do
      Shape.new(masked: false).default?(false).should be_true
    end

    it "still treats an unmasked client→server frame as a departure" do
      Shape.new(masked: false).default?(true).should be_false
    end

    it "treats a MASKED server→client frame as a departure" do
      Shape.new(masked: true).default?(false).should be_false
    end

    it "does not excuse any other departure on the inbound side" do
      Shape.new(fin: false).default?(false).should be_false
      Shape.new(rsv: 4).default?(false).should be_false
      Shape.new(declared_len: 99).default?(false).should be_false
    end

    it "leaves the no-argument form alone" do
      Shape.new.default?.should be_true
      Shape.new(masked: false).default?.should be_false
    end
  end

  describe "WsOutMessage#shape_label(to_server)" do
    it "does not call an unmasked server→client frame unmasked" do
      Msg.new(1, "hi".to_slice, Shape.new(masked: false)).shape_label(false).should eq("TEXT")
    end

    it "names the §5.1 violation on the client→server side" do
      Msg.new(1, "hi".to_slice, Shape.new(masked: false)).shape_label(true).should eq("TEXT unmasked")
    end

    it "names a masked server→client frame, which is the inbound violation" do
      Msg.new(1, "hi".to_slice, Shape.new(masked: true)).shape_label(false).should eq("TEXT masked")
    end

    it "keeps naming every direction-independent departure inbound" do
      label = Msg.new(9, "p".to_slice, Shape.new(fin: false, rsv: 4, masked: false)).shape_label(false)
      label.should eq("PING fin=0 rsv=4")
    end

    it "defaults to the client→server reading, which is what a send-side caller means" do
      Msg.new(1, "hi".to_slice, Shape.new(masked: false)).shape_label.should eq("TEXT unmasked")
    end
  end
end
