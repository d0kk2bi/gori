module Gori
  # One durable-write implementation for every config/state file gori owns.
  #
  # Six independent temp+rename impls grew up here (settings, the decoder-session
  # eraser, the capture-status marker, the active-project marker, the CA pair, the
  # MCP client configs) and only the last one got all four parts right. The other
  # five each dropped a different one, so the same crash was fixed once and left
  # live everywhere else. The parts, and why each is load-bearing:
  #
  # * **Resolve a symlink to its target first.** These are dotfiles, which people
  #   routinely symlink into a dotfiles repo, and `gori --config` invites exactly
  #   that. `File.write` wrote THROUGH the link; a rename over the link itself
  #   quietly detaches it — the tool then reads a plain file while the repo copy it
  #   was linked to goes stale, with nothing to show for it in `git status`. A
  #   HARDLINKED file is not detectable this way and does get detached (rename
  #   installs a new inode); that is the standing cost of an atomic replace.
  # * **fsync before the rename**, so the rename cannot land ahead of the bytes.
  #   Without it the crash the staging exists to survive still yields a truncated
  #   file — and gori's config loaders blanket-rescue a parse failure into factory
  #   defaults, so the loss is silent. The containing DIRECTORY is deliberately not
  #   fsync'd: that would make the rename itself durable, but its absence can only
  #   cost a crash the OLD file, never a torn one, and this runs on every settings
  #   save.
  # * **A randomized temp name.** `"#{path}.tmp"` is shared by every process that
  #   writes that path, so two gori instances stage over each other and one renames
  #   the other's half-written bytes into place. Randomized rather than pid-derived:
  #   a pid repeats, and a temp left behind by a killed run would then be re-opened
  #   (mode intact, since `perm` only applies on CREATE) and renamed into place at
  #   whatever mode it was abandoned with.
  # * **Carry the destination's mode across.** A credential-bearing config found at
  #   0600 must not come back 0644 because gori recreated it under the umask.
  module DurableFile
    # Stage *content* beside *path* and rename it into place.
    #
    # The string-content shorthand for `replace`; see `stage` for the mode rules.
    def self.write(path : String, content : String, *,
                   perm : File::Permissions, inherit : Bool = true) : Nil
      replace(path, perm: perm, inherit: inherit) do |tmp, mode|
        # Create at the final mode rather than widening under the umask and
        # narrowing after: the content is written before any chmod could run, so a
        # 0644 temp holding an auth-bearing config is a window the in-place
        # File.write never opened.
        File.open(tmp, "w", perm: mode) do |file|
          file.print(content)
          file.flush
          file.fsync
        end
      end
    end

    # A replacement fully written and fsync'd to a temp file, not yet renamed into
    # place. Splitting the write from the rename is what lets a caller replacing
    # SEVERAL files that must agree with each other (the CA's cert/key pair) get
    # every one of them onto disk before any of them lands, narrowing the window in
    # which the set disagrees to the gap between the renames.
    struct Staged
      def initialize(@tmp : String, @target : String)
      end

      def commit : Nil
        File.rename(@tmp, @target)
      end

      # Best-effort, and never raises: this runs on a path that is already failing,
      # and an unwritable directory or a read-only filesystem makes the delete raise
      # too. That exception would REPLACE the ENOSPC (or whatever actually failed)
      # with a permission complaint about a temp file the user has never heard of.
      def discard : Nil
        File.delete?(@tmp) rescue nil
      end
    end

    # Stage a replacement for *path* and rename it into place atomically.
    #
    # See `stage` for the block and mode rules.
    def self.replace(path : String, *, perm : File::Permissions, inherit : Bool = true,
                     &block : String, File::Permissions ->) : Nil
      staged = stage(path, perm: perm, inherit: inherit, &block)
      begin
        staged.commit
      rescue ex
        staged.discard
        raise ex
      end
    end

    # Write a replacement for *path* to a temp file beside it, without installing it.
    # Call `Staged#commit` to install, or `Staged#discard` to throw it away.
    #
    # The block receives the temp path to write and the mode that temp should end
    # up at — for a writer that opens the path itself (an OpenSSL BIO, say) the
    # mode has to be applied by the block before any bytes land, since this method
    # can only chmod after the fact.
    #
    # *perm* is the mode to land on when the destination does not exist yet. When
    # *inherit* is true an existing destination's own mode wins instead; pass
    # `inherit: false` for a file whose mode gori dictates rather than preserves
    # (settings.json holds env token values, so it is 0600 no matter what it was
    # found at).
    def self.stage(path : String, *, perm : File::Permissions,
                   inherit : Bool = true, & : String, File::Permissions ->) : Staged
      target = resolve_symlink(path)
      dir = File.dirname(target)
      mode = (inherit ? File.info?(target).try(&.permissions) : nil) || perm
      tmp = File.tempname(".#{File.basename(target)}.gori", ".tmp", dir: dir)
      staged = Staged.new(tmp, target)
      begin
        yield tmp, mode
        # chmod as well as creating at `mode`, because a block that opened the temp
        # itself may not have honoured the mode at all (an OpenSSL BIO does not).
        #
        # Rescued, unlike the reference impl's unrescued chmod, and that is safe only
        # because it can no longer be the thing protecting a secret: the temp is
        # always a fresh name, so `File.open`'s `perm:` really does apply on CREATE,
        # and `KeyPair#write_pem` forces 0600 itself before any key byte lands. What
        # is left for this chmod to fix is a public file's mode, which is not worth
        # failing a settings save on a filesystem that cannot represent it.
        File.chmod(tmp, mode) rescue nil
        fsync(tmp)
      rescue ex
        staged.discard
        raise ex
      end
      staged
    end

    # Flush the staged file's bytes to the platter before it is renamed over live
    # data. Re-opened rather than fsync'd through the writer's own handle because
    # `replace`'s block may have written via something that is not a Crystal `File`
    # at all. Opened for APPEND, never "w" — "w" truncates, which on this path
    # would destroy the very bytes we are trying to make durable.
    #
    # Best-effort: a filesystem that cannot fsync (some network mounts) must not
    # turn every settings save into a failure. The rename below is still atomic;
    # only the crash-durability guarantee is lost.
    private def self.fsync(path : String) : Nil
      File.open(path, "a", &.fsync)
    rescue
    end

    # The path a symlink points at, or *path* itself. A broken link (or an
    # unreadable one) resolves to itself, so the write replaces the dangling link
    # with a real file rather than failing over it.
    private def self.resolve_symlink(path : String) : String
      return path unless File.symlink?(path)
      File.realpath(path)
    rescue
      path
    end
  end
end
