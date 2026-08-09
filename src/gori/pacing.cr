module Gori
  # The outbound rate-limit policy the four request-driving engines share: Discover, Fuzz,
  # Miner and Sequencer.
  #
  # It is one policy, not four. Each engine had carried a byte-identical private copy of both
  # methods, and the drift that pattern invites had already happened in the comments: the
  # Fuzzer's copy alone records why the jitter `sleep` sits OUTSIDE the `if interval` guard
  # (gating it behind a base rate silently dropped jitter unless rps/throttle was also set),
  # while the other three carried the fixed code with no trace of the lesson. Anyone reading
  # the Miner's copy would have seen an unexplained line begging to be tidied back into the
  # branch. Sharing the code shares the reasoning with it.
  #
  # The including class supplies two things, which is the whole contract:
  #   `@config`         — responds to `rps`, `throttle_ms` and `jitter_ms`
  #   `@last_dispatch`  — a `Time::Instant` it also initialises
  #
  # `@last_dispatch` is deliberately the includer's own ivar rather than state owned here:
  # each engine keeps its clock ORCHESTRATOR-local (one fiber advances it) so pacing never
  # races across the worker fibers it dispatches to.
  module Pacing
    # The gap to hold between dispatches, or nil when the run is unthrottled.
    #
    # `rps` wins over `throttle_ms` when both are set — a requests-per-second budget is the
    # more specific statement of intent, and the two would otherwise compose into a rate
    # neither knob names.
    private def pace_interval : Time::Span?
      if (rps = @config.rps) && rps > 0
        (1.0 / rps).seconds
      elsif (t = @config.throttle_ms) && t > 0
        t.milliseconds
      else
        nil
      end
    end

    # Wait out the remaining gap before the next dispatch, then apply jitter.
    #
    # The clock is re-read AFTER the sleep rather than reusing `target`, so a scheduler that
    # overslept does not leave the next interval measured from a moment already past.
    private def pace(interval : Time::Span?) : Nil
      if interval
        now = Time.instant
        target = @last_dispatch + interval
        sleep(target - now) if now < target
        @last_dispatch = Time.instant
      end
      # Jitter applies on its own — don't gate it behind a base rate, which silently
      # dropped jitter unless rps/throttle was also set.
      sleep(rand(@config.jitter_ms).milliseconds) if @config.jitter_ms > 0
    end
  end
end
