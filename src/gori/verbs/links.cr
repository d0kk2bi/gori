require "../verb"

module Gori
  module Verbs
    # Repeater's/Fuzzer's own "Link to issue/note" (link.repeater.*/link.fuzzer.*) are
    # registered in register_miner (history.cr) instead of here — Round 5 moved them
    # there so their Repeater/Fuzzer COMMON menu position lands AFTER Fuzz/Mine (see
    # the comment at their new registration site for why). History's/HistoryDetail's/
    # Miner's own link verbs are unaffected and stay below.
    def self.register_links(r : Verb::Registry) : Nil
      flow_available = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :history && !ctx.link_flow_id.nil?
      }
      # The History LIST pair is batch-capable (#442): pick the issue/note once, attach every
      # marked flow. The HistoryDetail pair keeps flow_available — the detail is pinned to a
      # single flow, so marks deliberately don't apply there.
      #
      # Still gates on link_flow_id (an id that resolves), so the invariant flow_available
      # protects — never offer to attach evidence that doesn't exist — survives; marks are an
      # ALTERNATIVE way to satisfy it, for the case where every mark has scrolled out from
      # under the cursor. The handler additionally skips ids the store can't resolve, so a
      # stale mark can't file an orphan link row either way.
      flow_targets = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :history && (!ctx.link_flow_id.nil? || ctx.marked_flow_count > 0)
      }
      miner_linkable = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :miner && !ctx.link_miner_id.nil?
      }

      r.register Verb::Definition.new(
        "link.history.to-issue", "Link to issue", "Attach the selected/marked flows to an issue",
        Verb::Scope::Body, available: flow_targets, mnemonic: 'k') { |ctx| ctx.link_to_issue; nil }

      r.register Verb::Definition.new(
        "link.history.to-note", "Link to note", "Attach the selected/marked flows to a note",
        Verb::Scope::Body, available: flow_targets, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }

      r.register Verb::Definition.new(
        "link.history-detail.to-issue", "Link to issue", "Attach this flow to an issue",
        Verb::Scope::HistoryDetail, available: flow_available, mnemonic: 'k') { |ctx| ctx.link_to_issue; nil }

      r.register Verb::Definition.new(
        "link.history-detail.to-note", "Link to note", "Attach this flow to a note",
        Verb::Scope::HistoryDetail, available: flow_available, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }

      r.register Verb::Definition.new(
        "link.miner.to-issue", "Link to issue", "Attach this miner session to an issue",
        Verb::Scope::Miner, available: miner_linkable, mnemonic: 'k') { |ctx| ctx.link_to_issue; nil }

      r.register Verb::Definition.new(
        "link.miner.to-note", "Link to note", "Attach this miner session to a note",
        Verb::Scope::Miner, available: miner_linkable, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }
    end
  end
end
