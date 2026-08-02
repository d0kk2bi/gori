require "json"
require "../../cookie"

module Gori
  module MCP
    class Tools
      # --- signed-session-cookie workbench tools (pure compute; always exposed) ---
      # The JWT siblings for Flask / Rack / Django cookies. cookie_decode mirrors the
      # `decode` shape from Cookie.decode_json; verify/crack/forge drive the same engine
      # as `gori run cookie`. No network, no store — a target's secret is cracked offline.

      private def cookie_decode_tool(h) : Result
        cookie = str(h, "cookie")
        return Result.new("missing required 'cookie'", is_error: true) if cookie.nil? || cookie.strip.empty?
        Result.new(Cookie.decode_json(cookie.strip, cookie_format(h)))
      rescue ex : Cookie::CookieError
        Result.new(ex.message || "not a decodable cookie", is_error: true)
      end

      private def cookie_verify_tool(h) : Result
        cookie = str(h, "cookie")
        return Result.new("missing required 'cookie'", is_error: true) if cookie.nil? || cookie.strip.empty?
        secret = str(h, "secret")
        return Result.new("missing required 'secret'", is_error: true) if secret.nil?
        ok = cookie_verify(cookie.strip, secret, h)
        Result.new(JSON.build { |j| j.object { j.field "valid", ok; j.field "format", cookie_resolved_format(cookie.strip, h) } })
      rescue ex : Cookie::CookieError
        Result.new(ex.message || "not a decodable cookie", is_error: true)
      end

      private def cookie_crack_tool(h) : Result
        cookie = str(h, "cookie")
        return Result.new("missing required 'cookie'", is_error: true) if cookie.nil? || cookie.strip.empty?
        c = cookie.strip
        inline = str_list(h, "secrets")
        wordlist = str(h, "wordlist").try(&.presence)
        if inline.empty? && wordlist.nil?
          return Result.new("provide 'secrets' (array) and/or 'wordlist' (file path)", is_error: true)
        end
        found = cookie_crack_search(c, inline, wordlist, h)
        Result.new(JSON.build do |j|
          j.object do
            j.field "found", !found.nil?
            j.field "secret", found if found
            j.field "format", cookie_resolved_format(c, h)
          end
        end)
      rescue ex : Cookie::CookieError
        Result.new(ex.message || "not a decodable cookie", is_error: true)
      rescue ex : Gori::Error # a missing/unreadable wordlist from Fuzz::WordlistFile
        Result.new(ex.message || "wordlist error", is_error: true)
      end

      # Try the inline candidates first (cheap, ordered), then stream the wordlist file.
      private def cookie_crack_search(c : String, inline : Array(String), wordlist : String?, h) : String?
        found = inline.empty? ? nil : cookie_crack(c, Fuzz::InlineList.new(inline), h)
        found ||= cookie_crack(c, Fuzz::WordlistFile.new(wordlist), h) if found.nil? && wordlist
        found
      end

      private def cookie_forge_tool(h) : Result
        format = str(h, "format").try(&.downcase)
        return Result.new("missing required 'format' (flask/rack/django)", is_error: true) if format.nil? || format.empty?
        secret = str(h, "secret")
        return Result.new("missing required 'secret'", is_error: true) if secret.nil?
        ts = int(h, "timestamp") || Time.utc.to_unix
        cookie = cookie_forge_build(format, secret, ts, h)
        Result.new(JSON.build { |j| j.object { j.field "cookie", cookie; j.field "format", format } })
      rescue ex : Cookie::CookieError # invalid JSON, missing payload/value, unknown format
        Result.new(ex.message || "invalid input", is_error: true)
      end

      # Build the forged cookie or raise CookieError with a caller-facing message. Rack takes
      # the opaque base64 `value`; Flask/Django take the session `payload` JSON.
      private def cookie_forge_build(format : String, secret : String, ts : Int64, h) : String
        case format
        when "flask"
          Cookie::Flask.forge(forge_payload(h), secret, ts, salt: str(h, "salt") || Cookie::Flask::SALT)
        when "django"
          Cookie::Django.forge(forge_payload(h), secret, ts,
            salt: str(h, "salt") || Cookie::Django::DEFAULT_SALT,
            algorithm: str(h, "algorithm") || Cookie::Django::DEFAULT_ALGO)
        when "rack"
          data = (str(h, "value") || str(h, "payload")).try(&.presence) ||
                 raise Cookie::CookieError.new("rack forge needs 'value' (the base64 Marshal cookie value)")
          Cookie::Rack.forge(data, secret)
        else
          raise Cookie::CookieError.new("unknown format #{format.inspect} (use flask/rack/django)")
        end
      end

      private def forge_payload(h) : String
        str(h, "payload").try(&.presence) ||
          raise Cookie::CookieError.new("missing required 'payload' (the session JSON to sign)")
      end

      # --- shared cookie helpers ----------------------------------------------

      # An optional 'format' pin (flask/rack/django), validated. nil = auto-detect.
      private def cookie_format(h) : String?
        f = str(h, "format").try(&.presence.try(&.downcase))
        return nil if f.nil?
        raise Cookie::CookieError.new("unknown format #{f.inspect} (use flask/rack/django)") unless Cookie::FORMATS.includes?(f)
        f
      end

      private def cookie_resolved_format(cookie : String, h) : String?
        cookie_format(h) || Cookie.detect(cookie)
      end

      # Verify honoring the per-format salt/algorithm knobs (Flask salt; Django salt+algo).
      private def cookie_verify(cookie : String, secret : String, h) : Bool
        case cookie_resolved_format(cookie, h)
        when "flask" then Cookie::Flask.verify(cookie, secret, salt: str(h, "salt") || Cookie::Flask::SALT)
        when "rack"  then Cookie::Rack.verify(cookie, secret)
        when "django" then Cookie::Django.verify(cookie, secret,
          salt: str(h, "salt") || Cookie::Django::DEFAULT_SALT,
          algorithm: str(h, "algorithm") || Cookie::Django::DEFAULT_ALGO)
        else raise Cookie::CookieError.new("unrecognized cookie format")
        end
      end

      private def cookie_crack(cookie : String, secrets, h) : String?
        case cookie_resolved_format(cookie, h)
        when "flask" then Cookie::Flask.crack(cookie, secrets, salt: str(h, "salt") || Cookie::Flask::SALT)
        when "rack"  then Cookie::Rack.crack(cookie, secrets)
        when "django" then Cookie::Django.crack(cookie, secrets,
          salt: str(h, "salt") || Cookie::Django::DEFAULT_SALT,
          algorithm: str(h, "algorithm") || Cookie::Django::DEFAULT_ALGO)
        else raise Cookie::CookieError.new("unrecognized cookie format")
        end
      end

      private def str_list(h, key : String) : Array(String)
        raw = h[key]?
        return [] of String unless raw
        arr = raw.as_a? || return [] of String
        arr.compact_map(&.as_s?)
      end
    end
  end
end
