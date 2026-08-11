require "./spec_helper"

# Three helpers that had drifted copies. Round 9 closed the absolute-form family; these are
# the rest of the same audit.
#
# WHAT THESE EXAMPLES PIN, precisely — the copies are all `private`, so none of them can be
# called from here:
#   * `Fmt.ago`   — FULLY covered. `history_view#fmt_time_relative` now literally delegates,
#                   so pinning the home pins the caller.
#   * `valid_ipv6?` — covers the GUARD the probe splitter now calls, not the fact that it
#                   calls it. Reverting the call site does NOT red this file.
#   * `Fmt.size`  — pins the home's rounding convention only. `ProjectView#human_size` is a
#                   separate implementation (prose spacing, a TB step) that was taught the
#                   same rule; reverting it does NOT red this file either.
# Said out loud because two of the three would otherwise read as regression guards for
# changes they cannot see.
describe "one-home helpers" do
  describe "Fmt.size rounding convention" do
    # The module docstring names this exact case as what it exists to prevent: pick the unit
    # from the ROUNDED magnitude so a value just under a boundary rolls up, instead of the
    # misleading "1024KB". `ProjectView#human_size` compared the UNROUNDED value and printed
    # "1024.0 KB" for the same input.
    it "rolls a value just under a boundary up to the next unit" do
      Gori::Tui::Fmt.size(1_048_575_i64).should eq("1.0MB")
      Gori::Tui::Fmt.size(1_048_576_i64).should eq("1.0MB")
    end

    it "still reports a value clear of the boundary in its own unit" do
      Gori::Tui::Fmt.size(1_047_000_i64).should eq("1022KB")
      Gori::Tui::Fmt.size(512_i64).should eq("512B")
    end
  end

  describe "Upstream.split_host_port IPv6 disambiguation" do
    # An unbracketed authority is a whole IPv6 host only when it is a valid v6 literal — a
    # port cannot be told apart from the address colons. The probe rules' own splitter
    # omitted this, turning "::1" into host ":" port 1.
    it "treats a bare v6 literal as the whole host" do
      Gori::Proxy::Upstream.valid_ipv6?("::1").should be_true
      Gori::Proxy::Upstream.valid_ipv6?("2001:db8::1").should be_true
      Gori::Proxy::Upstream.split_host_port("::1", 443).should eq({"::1", 443})
      Gori::Proxy::Upstream.split_host_port("2001:db8::1", 443).should eq({"2001:db8::1", 443})
    end

    it "still splits a host:port and a bracketed literal" do
      Gori::Proxy::Upstream.valid_ipv6?("acme.test").should be_false
      Gori::Proxy::Upstream.split_host_port("acme.test:8443", 443).should eq({"acme.test", 8443})
      Gori::Proxy::Upstream.split_host_port("[::1]:8080", 443).should eq({"::1", 8080})
    end

    # The rule the home's comment states: a multi-colon authority that is NOT a valid v6
    # literal splits on the LAST colon, so a real port is not swallowed into the host.
    it "splits a multi-colon authority that is not a v6 literal" do
      Gori::Proxy::Upstream.valid_ipv6?("127.0.0.1:19110:bogus").should be_false
    end
  end

  describe "Fmt.ago" do
    it "formats each magnitude the same way every caller expects" do
      now = Time.local
      Gori::Tui::Fmt.ago(now - 3.seconds).should eq("3s")
      Gori::Tui::Fmt.ago(now - 5.minutes).should eq("5m")
      Gori::Tui::Fmt.ago(now - 2.hours).should eq("2h")
      Gori::Tui::Fmt.ago(now - 25.hours).should eq("1d")
    end

    # Clamped at 0 so clock skew never renders a negative age — the property every copy
    # carried and the reason they were collapsed into one.
    it "clamps a future timestamp to zero rather than showing a negative age" do
      Gori::Tui::Fmt.ago(Time.local + 10.seconds).should eq("0s")
    end
  end
end
