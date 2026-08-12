require "./spec_helper"

# `Bindings#add`/`#update` returned nil (= success) whatever the store answered, so MCP reported
# `updated: true` for an extract rule that never changed and the TUI form closed on a rule that
# was never saved. Worse for `update`: it ran its RENAME side effect — dropping the in-memory
# value observed under the old name — for a rename the store had refused.
private def bindings_store(&)
  path = File.tempname("gori-bindings-refusal", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe Gori::Bindings do
  it "reports a refused insert instead of claiming the rule was added" do
    bindings_store do |store|
      bindings = Gori::Bindings.load(store)
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil # the happy path
      store.flush

      store.close # every write from here answers "dropped"
      bindings.add("OTHER", "", Gori::ExtractKind::Cookie, "other")
        .should eq(Gori::Bindings::STORE_REFUSED)
    end
  end

  it "reports a refused update and leaves the rule exactly as it was" do
    path = File.tempname("gori-bindings-refusal2", ".db")
    begin
      store = Gori::Store.open(path)
      bindings = Gori::Bindings.load(store)
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      store.flush
      id = store.extract_rules.find { |r| r.name == "SESSION" }.not_nil!.id

      store.close # every write from here answers "did not commit"
      bindings.update(id, "RENAMED", "", Gori::ExtractKind::Cookie, "sid")
        .should eq(Gori::Bindings::STORE_REFUSED)

      # The refusal is the truth: reopened, the rule still carries its old descriptor. The
      # `return` also sits BEFORE the rename side effect, so the in-memory value observed under
      # the old name is not dropped for a rename that never happened.
      reopened = Gori::Store.open(path)
      begin
        reopened.extract_rules.map(&.name).should eq(["SESSION"])
      ensure
        reopened.close
      end
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
      File.delete?("#{path}.open.lock")
    end
  end
end
