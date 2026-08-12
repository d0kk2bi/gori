module Gori::Tui
  # The one sentence every workbench tab-close says when the store refused to remove the saved
  # session, and the one place that decides how it reads.
  #
  # `Store#delete_repeater` / `#delete_fuzz_session` / `#delete_miner_session` /
  # `#delete_sequencer_session` all report whether the DELETE committed. The tab leaves the list
  # either way — the operator asked to close it — but a rolled-back batch (another instance holding
  # the project's writer) leaves the saved session on disk, so it reappears on the next project
  # open. Four controllers were carrying this verbatim; any change to the wording, or a decision to
  # also log it, needed four edits and one missed site silently reverted to the old "closed" lie.
  module TabClose
    def self.message(base : String, orphaned : Bool) : String
      return base unless orphaned
      "#{base} — the saved tab could NOT be removed (project busy); it will reappear"
    end
  end
end
