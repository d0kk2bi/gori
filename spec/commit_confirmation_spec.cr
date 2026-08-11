require "./spec_helper"

# NOTE: `Store#close` is NOT idempotent — it blocks on `@done.receive`, which the writer
# fiber only ever sends once, so a second call hangs forever. Every example here closes the
# store itself (that is the lever for a failed commit), so the helper must not close it again.
private def with_store(&)
  path = File.tempname("gori-commit", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# One class, four sites: a mutation whose store answered "did this COMMIT" threw the answer
# away, and the surface above it reported success regardless. A closed store is the cheap
# stand-in for the busy/locked/closing case those answers exist for — `exec_task_ok` returns
# false rather than raising.
describe "commit confirmation" do
  describe "Scope sandbox setters" do
    # The sandbox is a BLOCKING gate, and one Scope instance is shared by the Interceptor and
    # every Outbound built from it. A dropped write is therefore not just "does not survive
    # restart": `reload` re-reads the persisted value and reverts the gate a surface already
    # announced as on.
    it "reports whether the flag committed" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.enable_sandbox.should be_true
        scope.disable_sandbox.should be_true
        scope.toggle_sandbox.should be_true

        store.close
        scope.enable_sandbox.should be_false
      end
    end

    it "matches the enabled-flag sibling beside it" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.enable.should be_true
        store.close
        scope.enable.should be_false
        scope.enable_sandbox.should be_false
      end
    end
  end

  describe "Store#set_probe_mode" do
    # Lowering the mode to stop active probing is the direction that matters: every surface
    # reported it done while a separate live instance kept the persisted mode and kept firing.
    it "reports whether the mode committed" do
      with_store do |store|
        store.set_probe_mode(Gori::Probe::Mode::Active).should be_true
        store.probe_mode.should eq(Gori::Probe::Mode::Active)

        store.close
        store.set_probe_mode(Gori::Probe::Mode::Off).should be_false
      end
    end
  end

  describe "Rules#add / #update" do
    it "reports whether the write committed" do
      with_store do |store|
        rules = Gori::Rules.load(store)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "A", "B").should be_true
        id = rules.rules.first.id
        rules.update(id, Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "A", "C").should be_true

        store.close
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "X", "Y").should be_false
        rules.update(id, Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "A", "D").should be_false
      end
    end

    # An empty pattern is refused before any write, and the caller cannot tell that apart
    # from a failure — both mean "no rule was added", which is what the surfaces report.
    it "refuses an empty pattern without claiming a write" do
      with_store do |store|
        rules = Gori::Rules.load(store)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "", "B").should be_false
        rules.rules.should be_empty
      end
    end
  end
end
