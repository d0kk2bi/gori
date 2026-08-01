require "../url"

module Gori::Tui
  # Small URL display helpers shared across views (History list, Intercept queue …).
  module Url
    # The request target in origin-form for display. Plaintext forward-proxy requests
    # are captured ABSOLUTE-form (`http://host/path` — the wire truth, P7); strip the
    # scheme+authority so a path column / queue label reads like the HTTPS (origin-form)
    # rows instead of gluing the host onto a full URL ("example.comhttp://example.com/x").
    # Non-URL targets (e.g. a response's "405 Method Not Allowed") pass through unchanged.
    #
    # The rule itself now lives in core `Gori::Url` — `Interceptor::Item` is core and needed
    # the same answer, and the two `target.starts_with?("http")` copies in `CLI::Output` and
    # `Links` were a THIRD spelling that disagreed with this one on an uppercase scheme. This
    # stays as the TUI's name for it so the eight call sites in `tui/` read unchanged.
    def self.origin_path(target : String) : String
      Gori::Url.origin_path(target)
    end
  end
end
