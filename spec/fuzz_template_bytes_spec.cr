require "./spec_helper"

private alias T = Gori::Fuzz::Template

# `Template.parse` iterated `marked.chars`, and Crystal's char iteration substitutes U+FFFD
# for every byte that is not valid UTF-8. So the template layer — which every fuzz run passes
# through, on every surface, whether or not anything is marked — silently rewrote any request
# body carrying raw 0x80-0xFF: a protobuf/gRPC frame, a gzip'd or otherwise binary POST, a
# latin-1 form field. Each such byte became the THREE bytes of the replacement character, so
# every request the sweep sent differed in length from the one it was seeded with, under a
# Content-Length recomputed to match the corruption, and nothing anywhere said so.
#
# `gori run fuzz --request FILE` and a piped stdin reach this with no scrub in front of them,
# so it is directly reachable, not only via a capture.
describe "Gori::Fuzz::Template — byte fidelity" do
  it "round-trips a body with invalid UTF-8 through parse → render unchanged" do
    raw = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\n" +
          String.new(Bytes[0x80, 0xFE, 0x00, 0xFF, 0xC0])
    tmpl = T.parse(raw)
    tmpl.position_count.should eq(0)
    tmpl.render([] of String).to_a.should eq(raw.to_slice.to_a)
  end

  it "splices a payload into a marked position while the binary body around it survives" do
    prefix = "POST /u?id=".to_slice
    marked = String.new(prefix) + "§1§" + " HTTP/1.1\r\nHost: h\r\n\r\n" +
             String.new(Bytes[0xC3, 0x28, 0x9F, 0x0A])
    tmpl = T.parse(marked)
    tmpl.position_count.should eq(1)
    rendered = tmpl.render(["99"])
    String.new(rendered).should start_with("POST /u?id=99 HTTP/1.1")
    rendered[-4..].to_a.should eq([0xC3, 0x28, 0x9F, 0x0A])
  end

  it "keeps a lone 0xA7 byte — the second half of §'s encoding — as itself" do
    # 0xA7 alone is not §; only the C2 A7 pair is. A char scan turned the bare byte into
    # U+FFFD; a byte scan that matched on 0xA7 alone would instead open a bogus position.
    raw = "POST /x HTTP/1.1\r\n\r\n" + String.new(Bytes[0xA7, 0x41, 0xC2])
    tmpl = T.parse(raw)
    tmpl.position_count.should eq(0)
    tmpl.render([] of String).to_a.should eq(raw.to_slice.to_a)
  end

  it "still honours §§ escapes, ¦chains and an unbalanced trailing § over bytes" do
    tmpl = T.parse("A§§B§v¦b64§C§tail")
    tmpl.position_count.should eq(1)
    tmpl.positions[0].default.should eq("v")
    tmpl.positions[0].chain.should eq("b64")
    # `A§B` literal, the position, then the unbalanced trailing § folded back as text.
    String.new(tmpl.render(["X"])).should eq("A§BXC§tail")
  end

  it "keeps a ¦¦ escape and a second bare ¦ literal inside the chain" do
    tmpl = T.parse("§a¦¦b¦c¦d§")
    tmpl.positions[0].default.should eq("a¦b")
    tmpl.positions[0].chain.should eq("c¦d")
  end

  it "renders the defaults back to the original bytes when nothing is substituted" do
    src = "GET /p?a=§1§&b=§two§ HTTP/1.1\r\nHost: h\r\n\r\n"
    tmpl = T.parse(src)
    String.new(tmpl.render(tmpl.default_payloads)).should eq("GET /p?a=1&b=two HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  it "does not lose the byte count on a body that is entirely high bytes" do
    body = Bytes.new(256) { |i| i.to_u8 }
    raw = "POST /b HTTP/1.1\r\nContent-Length: 256\r\n\r\n" + String.new(body)
    T.parse(raw).render([] of String).size.should eq(raw.to_slice.size)
  end
end
