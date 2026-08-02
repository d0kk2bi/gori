require "../spec_helper"

# Round 4 / F1. `dial_tls_result` has always returned a `DialError` whose `kind` says WHICH
# layer broke — that is the documented reason `DialErrorKind` exists — and the proxy path has
# consumed it since #323. Every DIRECT sender (repeater, fuzz, mine, sequence, discover, probe
# active, and `ConnPool`, all of which reach the network through `Repeater::Engine`) read only
# `detail` and fell through to one sentence:
#
#   connect failed: host:port — host unreachable (DNS/refused/timeout) or the origin's TLS
#   certificate failed verification (e.g. self-signed/expired)
#
# A cert rejection, a handshake failure and a plain TCP refusal have three different fixes
# (add their private CA / "this port is not TLS" / a firewall-DNS problem) and that sentence
# named the third for all three.

private alias U = Gori::Proxy::Upstream
private alias E = Gori::Repeater::Engine

private def tls_error : U::DialError
  U::DialError.new(U::DialErrorKind::Tls)
end

describe "Gori::Repeater::Engine.connect_error" do
  it "names a certificate rejection, with the remedy, under verify-on" do
    msg = E.connect_error("https", "h.test", 443, true, tls_error)
    msg.should contain("TLS verification failed: h.test:443")
    msg.should contain("certificate is not trusted")
    msg.should contain("SSL_CERT_FILE")
    # Not the reachability sentence — that is the whole defect.
    msg.should_not contain("host unreachable")
  end

  it "names a HANDSHAKE failure under -k, where verification is not the explanation" do
    msg = E.connect_error("https", "h.test", 443, false, tls_error)
    msg.should contain("TLS handshake failed: h.test:443")
    msg.should contain("may not be TLS")
    msg.should_not contain("host unreachable")
    # …and it must not offer -k to someone who already passed it.
    msg.should_not contain("SSL_CERT_FILE")
  end

  it "keeps the reachability sentence for a TCP failure, WITHOUT the TLS clause" do
    # `dial_tls_result` returns Connect (not Tls) when the socket itself never came up, so
    # this is now reachable only when the TCP layer really is what failed.
    https = E.connect_error("https", "h.test", 443, true, U::DialError::ORIGIN_UNREACHABLE)
    https.should eq("connect failed: h.test:443 — host unreachable (DNS/refused/timeout)")
    https.should_not contain("certificate")
    http = E.connect_error("http", "h.test", 80, false, U::DialError::ORIGIN_UNREACHABLE)
    http.should eq("connect failed: h.test:80 — host unreachable (DNS/refused/timeout)")
  end

  it "still uses a proxy detail VERBATIM, in preference to any kind-derived sentence" do
    # The #F3 case: a corporate proxy that refused the tunnel. The origin was never contacted,
    # so neither the TLS nor the reachability wording may replace what the dialer said.
    err = U::DialError.new(U::DialErrorKind::Proxy, "proxy.test:8080 wants credentials (407)")
    E.connect_error("https", "h.test", 443, true, err)
      .should eq("connect failed: proxy.test:8080 wants credentials (407)")
  end

  it "falls back to the reachability sentence when there is no DialError at all" do
    E.connect_error("https", "h.test", 443, true, nil)
      .should eq("connect failed: h.test:443 — host unreachable (DNS/refused/timeout)")
  end

  it "gives the three failures three DIFFERENT sentences" do
    cert = E.connect_error("https", "h.test", 443, true, tls_error)
    shake = E.connect_error("https", "h.test", 443, false, tls_error)
    tcp = E.connect_error("https", "h.test", 443, true, U::DialError::ORIGIN_UNREACHABLE)
    [cert, shake, tcp].uniq.size.should eq(3)
  end
end
