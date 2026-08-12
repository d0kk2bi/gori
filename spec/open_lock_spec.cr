require "./spec_helper"
require "file_utils"

private def with_project(&)
  root = File.tempname("gori-open-lock")
  begin
    registry = Gori::ProjectRegistry.new(root)
    yield registry, registry.create("target")
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# `ProjectRegistry#delete` refused a project whose CAPTURE lock was held, and its comment names
# the harm: rm_rf unlinks the db under a live writer, which then keeps "successfully" writing into
# a pathless inode. But capturing is not the only way to be writing — an MCP server takes no
# capture lock and writes issues, notes, repeaters and fuzz history all the same.
describe Gori::OpenLock do
  it "refuses to delete a project that another store has open" do
    with_project do |registry, project|
      store = Gori::Store.open(project.db_path)
      begin
        Gori::OpenLock.in_use?(project.db_path).should be_true
        expect_raises(Gori::Error, /open in another gori instance/) { registry.delete(project) }
        Dir.exists?(project.dir).should be_true # not wiped out from under the writer
      ensure
        store.close
      end

      # Closed ⇒ the lock is gone and the delete proceeds, so this is a retryable refusal and not
      # a project that can never be removed.
      Gori::OpenLock.in_use?(project.db_path).should be_false
      registry.delete(project)
      Dir.exists?(project.dir).should be_false
    end
  end

  it "stays in use until the LAST holder closes" do
    with_project do |registry, project|
      a = Gori::Store.open(project.db_path)
      b = Gori::Store.open(project.db_path) # a second instance: shared holders coexist
      begin
        Gori::OpenLock.in_use?(project.db_path).should be_true
        a.close
        Gori::OpenLock.in_use?(project.db_path).should be_true # b still has it
      ensure
        b.close
      end
      Gori::OpenLock.in_use?(project.db_path).should be_false
      registry.delete(project)
      Dir.exists?(project.dir).should be_false
    end
  end

  it "keys on the database, so another db in the same directory does not block it" do
    with_project do |registry, project|
      sibling = File.join(project.dir, "other.db")
      store = Gori::Store.open(sibling)
      begin
        # Two databases sharing a directory are two databases — the same rule the capture lock
        # and the capture-status marker are keyed by.
        Gori::OpenLock.in_use?(project.db_path).should be_false
        Gori::OpenLock.in_use?(sibling).should be_true
      ensure
        store.close
      end
    end
  end

  it "does not call a leftover lock file 'in use'" do
    with_project do |_registry, project|
      Gori::Store.open(project.db_path).close
      # The file persists after release, exactly like the capture lock's. Only a FAILED flock
      # means somebody is there.
      File.exists?(Gori::OpenLock.path(project.db_path)).should be_true
      Gori::OpenLock.in_use?(project.db_path).should be_false
    end
  end

  it "answers false for a database nobody ever opened, and for :memory:" do
    with_project do |_registry, project|
      Gori::OpenLock.in_use?(File.join(project.dir, "never-opened.db")).should be_false
      Gori::OpenLock.in_use?(":memory:").should be_false
      # An in-memory store must open normally with no lock to take.
      store = Gori::Store.open(":memory:")
      store.count.should eq(0)
      store.close
    end
  end

  it "still refuses on the capture lock, with its own message" do
    with_project do |registry, project|
      # The two guards are separate questions and keep separate wording, so an operator is told
      # which one to act on.
      lock = Gori::CaptureLock.try(project.dir).not_nil!
      begin
        expect_raises(Gori::Error, /stop its capture first/) { registry.delete(project) }
      ensure
        lock.close
      end
      registry.delete(project)
      Dir.exists?(project.dir).should be_false
    end
  end
end
