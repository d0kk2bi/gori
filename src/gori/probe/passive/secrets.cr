module Gori
  module Probe
    module Passive
      # High-confidence credential shapes shared by body and WebSocket payload rules.
      # Evidence is always the credential TYPE label — NEVER the matched value.
      # {pattern, label}.
      #
      # Membership here means one thing: seeing this shape in a client-visible payload is a real
      # disclosure, because the shape is NEVER legitimately handed to a browser. That is what
      # earns the High severity. A shape an app routinely and correctly ships to its own client
      # does not belong in this list however secret-looking it is — see JWT below.
      module Secrets
        PATTERNS = [
          {/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, "AWS access key id"},
          {/\bAIza[0-9A-Za-z_\-]{35}\b/, "Google API key"},
          {/\bgh[pousr]_[0-9A-Za-z]{36}\b/, "GitHub token"},
          {/\bgithub_pat_[0-9A-Za-z_]{22,}\b/, "GitHub fine-grained token"},
          {/\bglpat-[0-9A-Za-z_\-]{20}\b/, "GitLab token"},
          {/\bxox[baprs]-[0-9A-Za-z\-]{10,}/, "Slack token"},
          # Stripe LIVE keys only (test keys aren't sensitive); the prefix is distinctive.
          {/\b(?:sk|rk)_live_[0-9A-Za-z]{20,}\b/, "Stripe secret key"},
          {/\bSG\.[\w\-]{16,}\.[\w\-]{16,}\b/, "SendGrid API key"},
          {/\bnpm_[0-9A-Za-z]{36}\b/, "npm access token"},
          {/-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----/, "private key block"},
          # Client-side shapes — these routinely ship hard-coded in HTML/JS bundles.
          {/\b\d{6,}-[0-9a-z]{32}\.apps\.googleusercontent\.com\b/, "Google OAuth client id"},
          {/\b(?:pk|sk)\.eyJ[\w\-]{20,}\.[\w\-]{20,}\b/, "Mapbox token"},
          {/\bhttps:\/\/hooks\.slack\.com\/services\/T[0-9A-Za-z]+\/B[0-9A-Za-z]+\/[0-9A-Za-z]{16,}/, "Slack webhook url"},
          {/\bSK[0-9a-f]{32}\b/, "Twilio api key"},
          # LLM provider keys. Both vendors' formats are prefix-anchored and long, so the
          # prefix alone is already the discriminator — the length floors just stop a prose
          # mention of the prefix ("keys start with sk-ant-") from matching.
          {/\bsk-ant-(?:api|admin)\d{2}-[A-Za-z0-9_\-]{40,}/, "Anthropic API key"},
          {/\bsk-proj-[A-Za-z0-9_\-]{40,}/, "OpenAI project key"},
          # Slack app-level token (`xapp-`), a shape the existing xox[baprs]- pattern does not
          # cover: different prefix, different body (version-counter, app id, 64 hex chars).
          {/\bxapp-\d-[A-Z0-9]+-\d+-[a-f0-9]{64}\b/, "Slack app-level token"},
          {/\bshp(?:at|ss|ca|pa)_[0-9a-f]{32}\b/, "Shopify access token"},
          {/\bsq0(?:atp|csp)-[A-Za-z0-9_\-]{20,}/, "Square access token"},
          # Telegram bot token: the `<numeric id>:AA…` shape is the distinctive part.
          {/\b\d{8,10}:AA[A-Za-z0-9_\-]{32,35}\b/, "Telegram bot token"},
          {/\bpypi-AgEIcHlwaS5vcmc[A-Za-z0-9_\-]{50,}/, "PyPI API token"},
          # Azure Storage connection string — AccountKey is the credential; the surrounding
          # DefaultEndpointsProtocol/AccountName literals make it unmistakable.
          {/AccountKey=[A-Za-z0-9+\/]{86}==/, "Azure Storage account key"},
          # A database/broker URI carrying inline credentials — the single most common shape a
          # leaked config file or a stack trace exposes. Guarded twice against the tutorial /
          # docs-page false positive that a bare `scheme://user:pass@host` would produce: the
          # password must be at least 8 characters (placeholder passwords in documentation are
          # `pass`, `pwd`, `secret`, `password`, `changeme`, all shorter or excluded below), and
          # the host must not be a loopback or a reserved example domain. Those two together are
          # what keep this out of the "every page that documents a connection string" trap.
          {/\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss|amqps?|clickhouse):\/\/
            [^\s:@\/]{1,64}:
            (?!password@|changeme@|secret@|yourpass)[^\s:@\/]{8,}
            @(?!localhost|127\.0\.0\.1|\[::1\]|example\.(?:com|org|net)\b)[\w.\-]+/x,
           "database URI with inline credentials"},
        ]

        # A JSON Web Token, held OUT of PATTERNS on purpose.
        #
        # Every shape above is one a server has no business sending to a browser, so finding one
        # is a disclosure. A JWT is the opposite: handing the client a token IS the design. A
        # login response, a refresh call, an RSC payload, a WebSocket auth frame — all deliver a
        # JWT over TLS to exactly the party it was minted for. Scoring that alongside a leaked AWS
        # key meant the High tier fired on essentially every authenticated app, and a High that
        # fires everywhere is a High nobody reads.
        #
        # It is still worth surfacing WHERE tokens flow, so the body/WebSocket rules report it as
        # its own Info-severity code (`jwt_in_body` / `jwt_in_ws`) rather than dropping it. That
        # also keeps it independently dismissible: muting routine token traffic on a host no
        # longer mutes a genuine key leak on the same host.
        #
        # Each segment ≥10 chars keeps random dotted tokens out; "eyJ" (base64url for `{"`) is the
        # distinctive first-byte anchor. Token weaknesses themselves (alg:none, missing exp, …)
        # are the separate `jwt` rule, which decodes the tokens a flow AUTHENTICATES with.
        JWT = {/\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b/, "JSON Web Token"}
      end
    end
  end
end
