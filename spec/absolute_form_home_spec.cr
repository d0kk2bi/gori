require "./spec_helper"

# `Url.absolute_form?` is the one home for "does this target already carry its own
# scheme+authority", and it is case-INSENSITIVE (RFC 3986 3.1: schemes are). Several callers
# had re-derived it as `starts_with?("http")` or as a case-SENSITIVE two-prefix test, and both
# spellings disagree with the home on inputs gori really sees — it captures wire bytes
# verbatim, so an uppercase scheme in a request line reaches these callers intact.
describe "the absolute-form predicate has one home" do
  it "separates the home from the loose starts_with?(\"http\") form" do
    # A host that merely BEGINS with "http" is not an absolute-form target.
    Gori::Url.absolute_form?("httpbin.org/x").should be_false
    Gori::Url.location("a.test", "httpbin.org/x").should eq("a.testhttpbin.org/x")

    # An uppercase scheme IS one, and must not have the host prepended again.
    Gori::Url.absolute_form?("HTTP://a.test:8080/abs").should be_true
    Gori::Url.location("a.test", "HTTP://a.test:8080/abs").should eq("HTTP://a.test:8080/abs")
  end

  describe "Sitemap.normalize_path" do
    # The case-sensitive pair kept the scheme+authority on an uppercase target, which then
    # got segmented into path nodes named "http:" and the host.
    it "reduces an uppercase-scheme target to its path" do
      Gori::Sitemap.normalize_path("HTTP://acme.test/login").should eq("/login")
      Gori::Sitemap.normalize_path("HTTPS://acme.test/a/b?q=1").should eq("/a/b?q=1")
    end

    it "leaves an origin-form target alone" do
      Gori::Sitemap.normalize_path("/login").should eq("/login")
      Gori::Sitemap.normalize_path("httpbin.org/x").should eq("httpbin.org/x")
    end
  end

  describe "Oast::Provider.normalize_endpoint" do
    # One home so the TUI's "is this the same endpoint?" comparison can reproduce it exactly:
    # a session stores the normalised form while the provider row holds whatever was typed.
    it "does not re-prefix a scheme that is already there in any case" do
      Gori::Oast::Provider.normalize_endpoint("oast.pro").should eq("https://oast.pro")
      Gori::Oast::Provider.normalize_endpoint("https://oast.pro/").should eq("https://oast.pro")
      Gori::Oast::Provider.normalize_endpoint("HTTPS://oast.pro").should eq("HTTPS://oast.pro")
      Gori::Oast::Provider.normalize_endpoint("HTTP://oast.pro").should eq("HTTP://oast.pro")
    end
  end
end
