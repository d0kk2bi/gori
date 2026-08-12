module Gori
  # Advisory "a process has this DATABASE open" lock — a SHARED flock every `Store.open` takes
  # and every `Store#close` releases. Many holders coexist (that is what shared means: two TUIs,
  # a TUI plus an MCP server, a short-lived count), and a single non-blocking EXCLUSIVE probe
  # fails while any of them is alive, which is the one question `ProjectRegistry#delete` has to
  # answer before an `rm_rf`.
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
  # Keyed on the DB FILE, always — no legacy per-directory form to preserve, unlike
  # `Project#capture_lock_path`. Two databases sharing a directory are two databases.
  #
  # BEST EFFORT throughout: a project directory that cannot be written yields no lock rather than
  # a failed open, and `in_use?` answers false when it cannot tell. It degrades to the behaviour
  # that existed before it, never to a store that will not open. Same flock caveats as
  # `CaptureLock`: advisory, and a no-op on some network filesystems.
  class OpenLock
    SUFFIX = ".open.lock"

    def self.path(db_path : String) : String
      "#{db_path}#{SUFFIX}"
    end

    # Take the shared lock for `db_path`, or nil when there is nothing to take it on (an
    # in-memory database, an unwritable directory). The caller keeps it for as long as the
    # database is open and `close`s it after.
    def self.try_shared(db_path : String) : OpenLock?
      return nil if db_path.empty? || db_path.starts_with?(':') # ":memory:" is not a file
      lock_path = path(db_path)
      return nil unless Dir.exists?(File.dirname(lock_path))
      file = File.open(lock_path, "a") # never "w": truncating races a peer's own open
      begin
        # BLOCKING is wrong here and non-blocking is not merely an optimisation: another shared
        # holder never conflicts, so the only thing this could ever wait for is the exclusive
        # probe below — and making a store open wait on a delete's probe would trade a refused
        # delete for a stalled open.
        file.flock_shared(blocking: false)
        new(file)
      rescue
        file.close rescue nil
        nil
      end
    end

    # Does any live process hold this database open? Answers by trying the EXCLUSIVE lock, which
    # fails while any shared holder is alive. The lock FILE existing is never "in use" — only a
    # failed flock is, exactly as `CaptureLock` documents.
    #
    # Note this includes THIS process's own open stores, and deliberately: a caller must not
    # `rm_rf` a database it is itself reading. Every current caller closes its short-lived handle
    # first (both delete previews do).
    def self.in_use?(db_path : String) : Bool
      return false if db_path.empty? || db_path.starts_with?(':')
      lock_path = path(db_path)
      return false unless File.exists?(lock_path) # nobody ever opened it here
      file = File.open(lock_path, "a")
      begin
        file.flock_exclusive(blocking: false)
        file.flock_unlock rescue nil
        false
      rescue IO::Error
        true # contended — somebody has it open
      ensure
        file.close rescue nil
      end
    rescue
      false # cannot tell (permissions, a vanished path) — do not invent a refusal
    end

    def initialize(@file : File)
    end

    def close : Nil
      @file.flock_unlock rescue nil
      @file.close rescue nil
    end
  end
end
