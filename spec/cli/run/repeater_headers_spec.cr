require "../../spec_helper"

# `gori run repeater <flow-id>` header editing: `-H` and `--rm-header`.
#
# The two shapes pinned here are ones an operator testing a target's header handling has to
# be able to produce, and neither was expressible before:
#
#   * TWO header lines with the SAME name. A second `-H "X: b"` used to overwrite the first
#     in a `Hash(String, String)`, so `-H` could emit at most one line per name — and how a
#     target resolves duplicate `Host`/`Content-Length`/`Cookie` lines is exactly the thing
#     under test. Repeating the flag now appends; a single flag still replaces.
#   * DELETING a header. There was no syntax at all (`-H "X"` with no colon was a silent
#     no-op), and `-H "X:"` means something different and equally wanted — send `X` with an
#     EMPTY value. So deletion needs its own flag rather than an overload.
#
# Deleting `Content-Length` or `Host` also has to switch OFF the machinery that would put it
# straight back (the body auto-resync, the `--target` Host sync) — otherwise the flag reads
# as doing nothing.
#
# The builder is driven directly (through the `*_for_spec` shim defined alongside the fix-#15
# examples in spec/repeater/repeater_bugfixes_spec.cr) rather than through a subprocess, so
# these assert the exact wire bytes — which is what the guarantee is about.
private HEAD = "POST /t HTTP/1.1\r\nHost: h\r\nX-Dup: one\r\nX-Dup: two\r\nContent-Length: 5\r\n\r\n"

private def build(headers : Array(String), removed = [] of String,
                  body_override : String? = nil, target : String? = nil) : String
  wire, _ = Gori::CLI::Run.build_single_flow_request_for_spec(
    HEAD.to_slice, "hello".to_slice, headers, body_override, target, removed)
  String.new(wire)
end

describe "gori run repeater — -H / --rm-header" do
  it "replaces every duplicate of a name with ONE line for a single -H" do
    # Unchanged behaviour, pinned: the h2 case (repeated cookie: lines) must not be left
    # half-overridden, so later duplicates are dropped, not kept.
    out = build(["X-Dup: three"])
    out.scan(/X-Dup: /).size.should eq(1)
    out.should contain("X-Dup: three\r\n")
    out.should_not contain("X-Dup: one")
  end

  it "emits ONE line per repeated -H of the same name, in flag order" do
    out = build(["X-Dup: three", "X-Dup: four"])
    out.should contain("X-Dup: three\r\nX-Dup: four\r\n")
    out.should_not contain("X-Dup: one")
    out.should_not contain("X-Dup: two")
  end

  it "appends duplicates for a name the captured head does not carry" do
    out = build(["X-New: a", "X-New: b"])
    out.should contain("X-New: a\r\n")
    out.should contain("X-New: b\r\n")
  end

  it "still distinguishes an EMPTY value from a deletion" do
    build(["X-Dup:"]).should contain("X-Dup: \r\n")
    build([] of String, ["X-Dup"]).should_not contain("X-Dup")
  end

  it "--rm-header deletes EVERY line with that name, case-insensitively" do
    out = build([] of String, ["x-DUP"])
    out.should_not contain("X-Dup")
    out.should contain("Host: h\r\n") # neighbours untouched
    out.should end_with("\r\n\r\nhello")
  end

  it "--rm-header Content-Length suppresses the auto-resync that would restore it" do
    # A body with no Content-Length and no Transfer-Encoding is a real framing test; the
    # resync must read the deletion as an intentional pin, exactly like an explicit -H CL.
    out = build([] of String, ["Content-Length"])
    out.should_not contain("Content-Length")
    out.should end_with("\r\n\r\nhello")
  end

  it "--rm-header Host suppresses the --target Host sync" do
    out = build([] of String, ["Host"], target: "http://other.example:8080")
    out.should_not contain("Host:")
  end

  it "leaves --target's Host sync alone when Host was not removed" do
    out = build([] of String, [] of String, target: "http://other.example:8080")
    out.should contain("Host: other.example:8080\r\n")
  end

  it "ignores an empty / whitespace-only --rm-header name" do
    out = build([] of String, ["", "   "])
    out.should contain("X-Dup: one\r\nX-Dup: two\r\n")
  end
end
