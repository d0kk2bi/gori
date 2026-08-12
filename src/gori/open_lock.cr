require "./paths"

module Gori
  # Advisory "a process has this DATABASE open" lock — a SHARED flock every `Store.open` takes
  # and every `Store#close` releases. Many holders coexist (that is what shared means: two TUIs,
  # a TUI plus an MCP server, a short-lived count), and an EXCLUSIVE acquire fails while any of
  # them is alive, which is the one question a destructive project operation has to answer.
  #
  # WHY IT IS NOT THE CAPTURE LOCK. `CaptureLock` answers "who is the capturer", and it must:
  # exactly one instance listens, and a second one opens view-only. `delete` used to ask THAT
  # question, and its comment states the harm precisely — "rm_rf would unlink the db out from
  # under the capturer, which would then keep 'successfully' writing flows into a now-pathless
  # inode — a silent, total loss of everything captured after the delete". The harm has nothing
  # to do with capturing, though. An MCP server takes no capture lock and writes issues, notes,
  # repeaters and fuzz history all the same, so one MCP server could delete the project another
  # was serving: reproduced with two servers, where the second kept answering
  # `{"id":2,"message":"Note created successfully"}` and reading its notes back while nothing
  # existed on disk. The lock this file adds is the question that was actually being asked.
  #
  # Keyed on the DATABASE, CANONICALIZED (`Paths.canonical_file`) — no legacy per-directory form
  # to preserve, unlike `Project#capture_lock_path`. Canonical because the two sides reach this
  # from different spellings of one path: the registry builds `db_path` from `$GORI_HOME` as it
  # was given, while `gori --db` takes whatever the operator typed. `$GORI_HOME` through a
  # symlink (a dotfiles-managed home, `/tmp` on macOS) would otherwise give one database two
  # lock files, and a probe against the wrong one answers "nobody has it open".
  #
  # BEST EFFORT throughout: a project directory that cannot be written yields no lock rather than
  # a failed open, and a destructive caller that could not lock anything proceeds rather than
  # being blocked forever. It degrades to the behaviour that existed before it, never to a store
  # that will not open. Same flock caveats as `CaptureLock`: advisory, and a no-op on some
  # network filesystems.
  class OpenLock
    SUFFIX = ".open.lock"

    # How hard `try_shared` retries. An exclusive holder is only ever a destructive operation's
    # guard, so contention here is brief — but it is NOT nothing: a non-blocking shared acquire
    # that gives up would leave the store running with no lock at all, silently, which is exactly
    # the case the lock exists for (a peer probing while we open). Bounded rather than blocking so
    # a store open can never be parked behind a long VACUUM.
    RETRY_ATTEMPTS = 6
    RETRY_DELAY    = 3.milliseconds

    def self.path(db_path : String) : String
      "#{Paths.canonical_file(db_path)}#{SUFFIX}"
    end

    # Is this a real file path we can lock at all? `:memory:` and the empty path are not.
    private def self.lockable?(db_path : String) : Bool
      !db_path.empty? && !db_path.starts_with?(':')
    end

    # Take the shared lock for `db_path`, or nil when there is nothing to take it on (an
    # in-memory database, an unwritable directory). The caller keeps it for as long as the
    # database is open and `close`s it after.
    def self.try_shared(db_path : String) : OpenLock?
      return nil unless lockable?(db_path)
      lock_path = path(db_path)
      return nil unless Dir.exists?(File.dirname(lock_path))
      # `File.open` INSIDE the rescue, not above it: an unwritable directory or a lock file owned
      # by a teammate raises `File::Error` here, and that is neither `DB::Error` nor `Gori::Error`,
      # so it would sail past every rescue on the open paths (`gori mcp` dies before the
      # handshake, `gori run capture` backtraces) — the opposite of what this class promises.
      file = File.open(lock_path, "a") # never "w": truncating races a peer's own open
      begin
        RETRY_ATTEMPTS.times do |attempt|
          file.flock_shared(blocking: false)
          return new(file)
        rescue IO::Error
          sleep RETRY_DELAY if attempt < RETRY_ATTEMPTS - 1
        end
        # Gave up. Say so: from here the database is open with nothing announcing it, which is
        # the one state a peer's delete cannot see. gori.log, not STDERR (#411).
        ::Log.warn { "open-lock: could not announce #{db_path} as open (contended); a peer's delete will not see it" }
        file.close rescue nil
        nil
      rescue
        file.close rescue nil
        nil
      end
    rescue
      nil # best effort — a store must open regardless
    end

    # Take the EXCLUSIVE lock and HOLD it, for a caller about to do something destructive to the
    # database. nil means a live process has it open — refuse. Non-nil is the guard to keep for
    # the duration and `close` after; it may hold no file at all (nothing was lockable), because
    # "could not lock" must degrade to proceeding, not to a project nobody can ever delete.
    #
    # Held across the destructive act rather than probed and released, so a peer cannot open the
    # database in the gap between the answer and the `rm_rf`.
    def self.try_exclusive(db_path : String) : OpenLock?
      return new(nil) unless lockable?(db_path)
      lock_path = path(db_path)
      return new(nil) unless File.exists?(lock_path) # nobody ever opened it here
      file = begin
        File.open(lock_path, "a")
      rescue
        return new(nil) # cannot tell — do not invent a refusal
      end
      begin
        file.flock_exclusive(blocking: false)
        new(file)
      rescue IO::Error
        file.close rescue nil
        nil # contended — somebody has it open
      rescue
        file.close rescue nil
        new(nil)
      end
    end

    # Does any live process hold this database open? One definition of contention, shared with
    # `try_exclusive`, for a caller that only wants to REPORT (a delete's dry run) rather than act.
    def self.in_use?(db_path : String) : Bool
      guard = try_exclusive(db_path)
      return true unless guard
      guard.close
      false
    end

    def initialize(@file : File?)
    end

    def close : Nil
      if file = @file
        file.flock_unlock rescue nil
        file.close rescue nil
      end
    end
  end
end
