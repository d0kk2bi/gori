module Gori::Tui
  # Multi-select for the ProjectPicker's list — the same mark model History, the Intercept
  # queue, the Sitemap tree and the Issues list carry (#442), lifted into a state object of
  # its own because the picker holds a live `Termisu` and so cannot be built in a spec: the
  # rule that decides which projects a `rm_rf` reaches has to be pinnable without one.
  #
  # Keyed on the project DIRECTORY, not the display name. The directory slug is unique and
  # survives a rename (ProjectRegistry#rename rewrites only the `.name` sidecar), so a mark
  # placed before a rename still names the same project afterwards.
  #
  # A mark is NOT confined to what the fuzzy filter currently shows: narrowing the query
  # after marking leaves the set intact (that is how you assemble a batch out of two
  # searches), which is why `hidden_count` exists and why the delete confirm spells the
  # split out — see ProjectPicker.delete_confirm_body.
  class ProjectMarks
    def initialize
      @marks = Set(String).new
      # Where a ⇧arrow range is measured from, and the ids that gesture itself added —
      # kept apart from deliberate Tab marks so ⇧↑ hands back only what ⇧↓ just took.
      @anchor = nil.as(String?)
      @extent = Set(String).new
    end

    def marked?(dir : String) : Bool
      @marks.includes?(dir)
    end

    def size : Int32
      @marks.size
    end

    # The one emptiness predicate — callers spell the positive as `!marks.empty?`. An `any?`
    # alias would read better at the call site but reads to a linter as `Enumerable#any?`
    # (Performance/AnyInsteadOfPresent), and a false positive per call site is a poor trade
    # for a negation.
    def empty? : Bool
      @marks.empty?
    end

    # Tab / ⇧Tab — flip one project's mark. The caller steps the cursor afterwards (the
    # picker owns its own row indices); the anchor lands on the row just toggled, so a Tab
    # followed by ⇧↓ extends from it.
    def toggle(dir : String) : Nil
      @marks.includes?(dir) ? @marks.delete(dir) : @marks.add(dir)
      @anchor = dir
      @extent.clear
    end

    # Ctrl-A — mark everything the CURRENT filter shows, unioned with what is already
    # marked, so narrowing the query twice accumulates rather than replaces.
    def mark_all(dirs : Enumerable(String), cursor : String? = nil) : Nil
      dirs.each { |d| @marks.add(d) }
      @anchor = cursor
      @extent.clear
    end

    def clear : Nil
      @marks.clear
      reset_anchor
    end

    # End a ⇧arrow range gesture AND hand back everything it marked — what letting go of ⇧
    # and pressing a plain arrow does in a GUI list, where the highlight collapses instead
    # of being left behind. Only the gesture's own dirs go: Tab marks are deliberate tags,
    # and dropping those too would put a discontiguous set out of reach ("this one, skip
    # three, that one"). Returns how many marks it gave back.
    def end_gesture : Int32
      before = @marks.size
      @extent.each { |d| @marks.delete(d) }
      reset_anchor
      before - @marks.size
    end

    # ⇧↑/⇧↓ — extend a contiguous range from the anchor, the keyboard form of a GUI
    # shift+click. `cursor` is an index into `dirs`; the new cursor index is returned. The
    # anchor is seeded from the cursor when it is unset or has fallen out of the filter, so
    # the first ⇧arrow always starts from where you are.
    def extend(dirs : Array(String), cursor : Int32, delta : Int32) : Int32
      return cursor if dirs.empty?
      anchor_idx = @anchor.try { |a| dirs.index(a) }
      unless anchor_idx
        @anchor = dirs[cursor]?
        anchor_idx = cursor
        @extent.clear
      end
      moved = (cursor + delta).clamp(0, dirs.size - 1)
      lo, hi = {anchor_idx, moved}.minmax
      wanted = Set(String).new
      (lo..hi).each { |i| dirs[i]?.try { |d| wanted.add(d) } }
      # Give back what THIS gesture added but the new range no longer covers, so ⇧↑ after
      # ⇧↓⇧↓ leaves two rows marked rather than three. @extent holds only the gesture's own
      # dirs, so a Tab mark survives a range sweeping over it and back off.
      (@extent - wanted).each { |d| @marks.delete(d) }
      added = wanted - @marks
      @marks.concat(added)
      @extent = (@extent & wanted) | added
      moved
    end

    # Drop specific marks — the post-delete prune, so a deleted project's dir can't linger
    # in the set and inflate the next count. Only what actually went: a project the delete
    # REFUSED stays marked, so the operator can close the other gori and press again.
    def unmark(dirs : Enumerable(String)) : Nil
      # Reset the anchor only when the anchor ITSELF went — an unmarked row that is still on
      # the list is a perfectly good place for the next ⇧arrow to measure from, which is why
      # HistoryView#unmark_ids keeps its anchor too (it asks `index_of(a).nil?`).
      anchor_gone = false
      dirs.each do |d|
        @marks.delete(d)
        @extent.delete(d)
        anchor_gone = true if d == @anchor
      end
      reset_anchor if anchor_gone
    end

    # Keep only marks that still name a live project, called wherever the picker re-lists
    # the registry. A project a peer deleted out from under us is not a target, and a count
    # that outlives the directory it points at is the one number here that must not lie.
    def retain(dirs : Enumerable(String)) : Nil
      live = dirs.to_set
      @marks.select! { |d| live.includes?(d) }
      @extent.select! { |d| live.includes?(d) }
      reset_anchor if (a = @anchor) && !live.includes?(a)
    end

    # Marks in DISPLAY order: the ones the filter is showing first, in list order, then the
    # off-window rest sorted by dir so the order is stable rather than Set-insertion order.
    def ordered(visible : Array(String)) : Array(String)
      shown = visible.select { |d| @marks.includes?(d) }
      hidden = (@marks - shown.to_set).to_a.sort!
      shown + hidden
    end

    # Marks whose project the current filter does NOT show. Surfaced next to the count and
    # again in the delete confirm, so a set larger than the visible list is never a surprise.
    def hidden_count(visible : Array(String)) : Int32
      return 0 if @marks.empty?
      shown = 0
      visible.each { |d| shown += 1 if @marks.includes?(d) }
      @marks.size - shown
    end

    # Forget where a range gesture started (and what it had added), so the next ⇧arrow
    # anchors at the cursor instead of sweeping back to a stale point.
    private def reset_anchor : Nil
      @anchor = nil
      @extent.clear
    end
  end
end
