require "../../spec_helper"
require "json"

# `gori run cookie` drives the shared Gori::Cookie engine (covered end-to-end in
# spec/cookie_spec.cr); this file pins the CLI-only glue. The emit_* helpers call `exit`,
# so they aren't invoked in-process — the input helper is the reachable seam.

# `cookie_input` is private CLI glue — reopen the module for a bare-call wrapper. Only the
# positional branch is exercised (the STDIN branch would block on a non-tty spec runner).
module Gori::CLI::Run
  def self.cookie_input_for_spec(positional : Array(String)) : String
    cookie_input(positional)
  end
end

describe "gori run cookie" do
  it "takes the cookie from the positional argument, trimmed" do
    # A cookie pasted from a terminal or piped through a shell routinely arrives with
    # surrounding whitespace/newline.
    Gori::CLI::Run.cookie_input_for_spec(["  #{RACK}\n"]).should eq(RACK)
  end

  it "the CLI and MCP share the decode_json shape (no divergence)" do
    # Both surfaces emit Gori::Cookie.decode_json — assert the contract once here.
    j = JSON.parse(Gori::Cookie.decode_json(FLASK))
    j["format"].as_s.should eq("flask")
    j["payload"]["user_id"].as_i.should eq(42)
    j["signature"].as_s.should_not be_empty
  end
end

private FLASK = "eyJ1c2VyX2lkIjo0MiwiYWRtaW4iOnRydWUsIm5hbWUiOiJhbGljZSJ9.am71Yg.gd2MWkbBsGdhg4rScrYWBdGoj-Q"
private RACK  = "BAh7BkkiCXVzZXIGOgZFVEkiCmFsaWNlBjsAVA==--9156ef2ac6989f37064259efa196770c3ee052ca"
