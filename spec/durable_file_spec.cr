require "./spec_helper"

# Six independent temp+rename impls collapsed into `DurableFile`, and each of the five
# non-reference ones had dropped a different part of the contract. These examples pin the
# parts, so a future caller cannot quietly reintroduce one of the five.
describe Gori::DurableFile do
  describe "symlink handling" do
    # The reason this module exists. `gori --config ~/dotfiles/gori.json` is the advertised
    # way to point gori at a version-controlled settings file; a rename over the link
    # detaches it, and the repo copy then goes stale with nothing to show in `git status`.
    it "writes THROUGH a symlink instead of replacing it" do
      DurableFileSpec.in_tmp do |dir|
        real = File.join(dir, "real.json")
        link = File.join(dir, "link.json")
        File.write(real, "old")
        File.symlink(real, link)

        Gori::DurableFile.write(link, "new", perm: DurableFileSpec::RW)

        File.symlink?(link).should be_true
        File.read(real).should eq("new")
      end
    end

    it "replaces a DANGLING symlink with a real file rather than failing" do
      DurableFileSpec.in_tmp do |dir|
        link = File.join(dir, "link.json")
        File.symlink(File.join(dir, "gone.json"), link)

        Gori::DurableFile.write(link, "new", perm: DurableFileSpec::RW)

        File.read(link).should eq("new")
      end
    end
  end

  describe "permissions" do
    it "carries an existing file's mode across the replace" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        File.write(path, "old")
        File.chmod(path, 0o600)

        Gori::DurableFile.write(path, "new", perm: DurableFileSpec::RW)

        File.info(path).permissions.should eq(File::Permissions.new(0o600))
      end
    end

    it "uses perm for a file that does not exist yet" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")

        Gori::DurableFile.write(path, "new", perm: File::Permissions.new(0o600))

        File.info(path).permissions.should eq(File::Permissions.new(0o600))
      end
    end

    # settings.json holds `env` token VALUES; a copy an older gori wrote at 0644 has to be
    # tightened on the way past, not carried forward. That is what `inherit: false` is for.
    it "forces perm over an existing mode when inherit is false" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "settings.json")
        File.write(path, "old")
        File.chmod(path, 0o644)

        Gori::DurableFile.write(path, "new", perm: File::Permissions.new(0o600), inherit: false)

        File.info(path).permissions.should eq(File::Permissions.new(0o600))
      end
    end
  end

  describe "temp files" do
    # `"#{path}.tmp"` was shared by every process writing that path — and, for settings.json,
    # by `Settings.save` and `drop_legacy_decoder_sessions` within one process. Two stagers
    # then wrote one file and one renamed the other's half-written bytes into place.
    it "does not derive the temp name from the destination alone" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        seen = [] of String
        2.times do
          Gori::DurableFile.stage(path, perm: DurableFileSpec::RW) { |tmp, _m| seen << tmp; File.write(tmp, "x") }.discard
        end
        seen.uniq.size.should eq(2)
        seen.should_not contain("#{path}.tmp")
      end
    end

    it "stages in the destination's own directory so the rename stays intra-filesystem" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        Gori::DurableFile.stage(path, perm: DurableFileSpec::RW) do |tmp, _m|
          File.dirname(tmp).should eq(dir)
          File.write(tmp, "x")
        end.discard
      end
    end

    # `write_active_project` swallowed every failure at a method-level rescue and left
    # `active_project.tmp.<pid>` behind; nothing in the tree ever swept those. A failing
    # write must clean up after itself AND surface the cause that actually failed, not a
    # complaint about a temp file the operator has never heard of.
    it "leaves no temp behind when the write raises, and reports the original cause" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        expect_raises(Gori::Error, "boom") do
          Gori::DurableFile.replace(path, perm: DurableFileSpec::RW) do |tmp, _m|
            # Write BEFORE raising: the leak this pins is a temp that reached the disk and
            # was then abandoned, which is the only way `active_project.tmp.<pid>` piled up.
            File.write(tmp, "partial")
            raise Gori::Error.new("boom")
          end
        end
        Dir.children(dir).should be_empty
      end
    end
  end

  describe "staging without committing" do
    # The CA writes a cert and a key that must agree. Both are staged in full before either
    # is renamed, so the on-disk pair never disagrees past the gap between the renames.
    it "does not touch the destination until commit" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        File.write(path, "old")

        staged = Gori::DurableFile.stage(path, perm: DurableFileSpec::RW) { |tmp, _m| File.write(tmp, "new") }
        File.read(path).should eq("old")

        staged.commit
        File.read(path).should eq("new")
      end
    end

    it "discards a staged replacement without disturbing the destination" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        File.write(path, "old")

        Gori::DurableFile.stage(path, perm: DurableFileSpec::RW) { |tmp, _m| File.write(tmp, "new") }.discard

        File.read(path).should eq("old")
        Dir.children(dir).should eq(["cfg.json"])
      end
    end
  end
end

# Helper namespace: `describe` blocks cannot host `def self.`, so the scratch-dir helper
# lives here.
module DurableFileSpec
  RW = File::Permissions.new(0o644)

  def self.in_tmp(&)
    dir = File.tempname("gori-durable")
    Dir.mkdir_p(dir)
    begin
      yield dir
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
