require "./spec_helper"
require "file_utils"

# Top-level `gori` dispatch (src/gori/cli.cr). Only the pure argv helpers are exercised
# here — CLI.run itself starts a TUI / server or calls `exit`, so it is not spec-callable.
#
# `global_version_flag?` is private; expose it the way the other CLI specs expose theirs
# (spec/cli/run/links_spec.cr does the same for resolve_link_ends / parse_link_id).
module Gori::CLI
  # Mirrors what CLI.run does: split off the top-level subcommand, then ask about the tail. Kept
  # at full-argv granularity so these cases read as real command lines.
  def self.global_version_flag_for_spec(argv : Array(String)) : Bool
    _, subargs = split_subcommand(argv)
    global_version_flag?(subargs)
  end

  # `gori settings` helpers. Only the PURE ones are reachable: the guards themselves end in
  # `abort`, which calls `exit` and is not catchable, so each of these is the decision the
  # abort is made on rather than the abort itself.
  def self.unknown_settings_verb_for_spec(args : Array(String)) : Bool
    unknown_settings_verb?(args)
  end

  def self.parse_sections_value_for_spec(value : String) : Array(String)
    parse_sections_value(value)
  end

  def self.unknown_sections_for_spec(list : Array(String)) : Array(String)
    unknown_sections(list)
  end

  # What the guards actually decide on. Routed through the PRODUCTION `stray_args` — its
  # `unknown_args` wiring included — so dropping the `after` half again fails these examples;
  # re-implementing the join here would have specced the spec. Only the parser is local, shaped
  # like bare `gori settings`'s, since the guards themselves end in `abort` (not catchable).
  # `edit` comes back too so that case can pin the ENTIRE original failure: nothing left over
  # AND the flag never fired — i.e. "printed the path and exited 0".
  def self.settings_argv_for_spec(args : Array(String)) : {Array(String), Bool}
    edit = false
    parser = OptionParser.new do |p|
      p.on("--edit", "Open the settings file in your editor") { edit = true }
      p.on("-h", "--help", "Show this help") { }
    end
    {stray_args(parser, args), edit}
  end

  # Same call, `import`'s parser — where the leftovers are FILENAMES rather than an error.
  def self.import_files_for_spec(args : Array(String)) : Array(String)
    parser = OptionParser.new do |p|
      p.on("--sections=LIST", "Sections to apply") { }
      p.on("--dry-run", "Print what would be applied") { }
      p.on("-h", "--help", "Show this help") { }
    end
    stray_args(parser, args)
  end

  def self.same_file_for_spec(a : String, b : String) : Bool
    same_file?(a, b)
  end
end

describe "gori — global version flag" do
  it "claims a version flag standing alone" do
    Gori::CLI.global_version_flag_for_spec(["-v"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["-V"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["--version"]).should be_true
  end

  it "claims a version flag against a TOP-LEVEL subcommand" do
    # print_main_help promises version/help work "at the top level too", and one non-flag
    # token — the top-level subcommand — is still the top level.
    Gori::CLI.global_version_flag_for_spec(["run", "-v"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["run", "--version"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["mcp", "-V"]).should be_true
    # CLI.run strips `--config PATH` before asking, so the PATH never counts against the
    # one-non-flag-token budget — `gori --config x.json tui -v` arrives here as ["tui", "-v"].
    Gori::CLI.global_version_flag_for_spec(["tui", "-v"]).should be_true
  end

  # The regression this helper exists for: a bare `-v` ANYWHERE in argv used to print the
  # version and return 0 without running the command — a silent no-op with a SUCCESS status.
  it "leaves a NESTED subcommand's own -v alone" do
    # rewriter add / preview document `-vVALUE, --value=VALUE`; this used to create no rule
    # and still exit 0.
    Gori::CLI.global_version_flag_for_spec(
      ["run", "rewriter", "add", "--op", "set_header", "--find", "X", "-v", "boom"]).should be_false
    Gori::CLI.global_version_flag_for_spec(
      ["run", "rewriter", "preview", "-v", "x"]).should be_false
  end

  it "leaves a nested option VALUE that happens to be a version flag alone" do
    # These sent zero requests / encoded nothing, and reported success.
    Gori::CLI.global_version_flag_for_spec(
      ["run", "decoder", "base64-encode", "--input", "-v"]).should be_false
    Gori::CLI.global_version_flag_for_spec(
      ["run", "fuzz", "--payloads", "-v"]).should be_false
    Gori::CLI.global_version_flag_for_spec(
      ["run", "fuzz", "--payloads", "--version"]).should be_false
    Gori::CLI.global_version_flag_for_spec(
      ["run", "history", "--query", "-V"]).should be_false
  end

  it "does not claim a version flag once a nested subcommand has been named" do
    Gori::CLI.global_version_flag_for_spec(["run", "capture", "-v"]).should be_false
    Gori::CLI.global_version_flag_for_spec(["run", "show", "1", "--version"]).should be_false
  end

  # Regression: keying on subargs[0] ALONE was too narrow. A version flag after a top-level
  # subcommand's own flag reached that subcommand's parser and aborted with "unknown option",
  # while `--help` in the same position worked because every parser owns `-h` — and
  # print_main_help plus docs/reference/cli.md both promise version works at the top level.
  it "claims a version flag after a top-level subcommand's own flags" do
    Gori::CLI.global_version_flag_for_spec(["mcp", "--read-only", "--version"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["ca", "--pem", "-v"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["tui", "--insecure-upstream", "-V"]).should be_true
  end

  # The scan stops dead at the first bare word, because that word is a nested verb and owns
  # everything after it. This is what keeps every case from the original bug excluded.
  it "stops at the first bare word, so a nested verb owns its own flags" do
    Gori::CLI.global_version_flag_for_spec(["run", "oast", "listen", "--version"]).should be_false
    Gori::CLI.global_version_flag_for_spec(["run", "probe", "rules", "-v"]).should be_false
    Gori::CLI.global_version_flag_for_spec(["run", "issues", "create", "-v", "x"]).should be_false
  end

  # KNOWN RESIDUAL, pinned so it is a decision and not a surprise: a `-v` that is the VALUE of a
  # top-level flag still reads as the flag, because telling a value from a flag needs to know
  # which flags take values, and that lives in each subcommand's OptionParser. Accepted because
  # it only misfires on input that is already invalid (`gori run --project x` is not a
  # subcommand either), whereas excluding it broke `gori mcp --read-only --version` above.
  it "still misreads a version flag used as a top-level flag's value" do
    Gori::CLI.global_version_flag_for_spec(["run", "--project", "-v"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["tui", "--db", "-v"]).should be_true
  end

  it "is false when there is no version flag at all" do
    Gori::CLI.global_version_flag_for_spec([] of String).should be_false
    Gori::CLI.global_version_flag_for_spec(["run", "history"]).should be_false
    # A near-miss must not match: only the exact tokens count.
    Gori::CLI.global_version_flag_for_spec(["--verbose"]).should be_false
    Gori::CLI.global_version_flag_for_spec(["-vv"]).should be_false
    Gori::CLI.global_version_flag_for_spec(["run", "decoder", "--input", "-vsomething"]).should be_false
  end
end

# `gori settings` argv guards. Each one closes a silent-no-op-carrying-SUCCESS hole — the
# failure mode the `global_version_flag?` comment above condemns at length, which `gori
# settings` was reproducing on a typo'd verb, an empty `--sections`, and a misspelt one.
describe "gori settings — subcommand dispatch" do
  it "rejects a bare word that is not one of the three verbs" do
    # `gori settings expor -o profile.json` used to print the settings path and exit 0: no
    # export, no file, and `… || die` never fires.
    Gori::CLI.unknown_settings_verb_for_spec(["expor"]).should be_true
    Gori::CLI.unknown_settings_verb_for_spec(["expor", "-o", "p.json"]).should be_true
    Gori::CLI.unknown_settings_verb_for_spec(["blahblah", "nonsense"]).should be_true
  end

  it "accepts the three verbs and every flag-only form" do
    Gori::CLI.unknown_settings_verb_for_spec(["export"]).should be_false
    Gori::CLI.unknown_settings_verb_for_spec(["import", "p.json"]).should be_false
    Gori::CLI.unknown_settings_verb_for_spec(["sections"]).should be_false
    # Bare `gori settings`, and the flag forms it has always taken.
    Gori::CLI.unknown_settings_verb_for_spec([] of String).should be_false
    Gori::CLI.unknown_settings_verb_for_spec(["--edit"]).should be_false
    Gori::CLI.unknown_settings_verb_for_spec(["-h"]).should be_false
  end
end

describe "gori settings — --sections parsing" do
  it "trims and drops empties" do
    Gori::CLI.parse_sections_value_for_spec("network, theme ").should eq(["network", "theme"])
    Gori::CLI.parse_sections_value_for_spec("network,,theme").should eq(["network", "theme"])
  end

  # The caller aborts on an empty result. It has to check emptiness explicitly: `[] of String`
  # is TRUTHY in Crystal, so `if list = sections` used to pass with nothing in it, and
  # `--sections=""` exported `{}` / imported nothing at exit 0 — where a shell expanding an
  # unset variable lands.
  it "yields nothing for an empty or all-comma value" do
    Gori::CLI.parse_sections_value_for_spec("").should be_empty
    Gori::CLI.parse_sections_value_for_spec(",,,").should be_empty
    Gori::CLI.parse_sections_value_for_spec("  ").should be_empty
  end
end

# The `--` separator used to switch every guard above back off. OptionParser strips the run
# after it and hands it over as a SECOND list, which `gori settings` discarded — so two
# characters turned each of these back into the silent-no-op-at-exit-0 the guards exist to
# stop. `gori wizard` / `gori tutorial` already handled it (reject_extra_args); settings did not.
describe "gori settings — arguments after a `--` separator" do
  it "sees a flag pushed past `--` as the stray argument it is" do
    # `gori settings -- --edit` printed the settings path and exited 0, editor never opened.
    rest, edit = Gori::CLI.settings_argv_for_spec(["--", "--edit"])
    edit.should be_false # OptionParser will not claim it, which is exactly why it must be refused
    rest.should eq(["--edit"])
  end

  it "sees a bare word pushed past `--`" do
    # `gori settings export -- team.json` (a `--` where `-o` was meant) dumped the profile to
    # stdout, created no file, and exited 0 — verbatim the failure reject_stray_args! was
    # written for, reached around it.
    Gori::CLI.settings_argv_for_spec(["--", "team.json"]).should eq({["team.json"], false})
    Gori::CLI.settings_argv_for_spec(["--", "foo"]).should eq({["foo"], false})
  end

  it "leaves an ordinary invocation alone" do
    # No `--` at all, and a bare `--` with nothing after it, must both stay clean — the guard
    # aborts on any leftover, so a false positive here breaks a working command.
    Gori::CLI.settings_argv_for_spec(["--edit"]).should eq({[] of String, true})
    Gori::CLI.settings_argv_for_spec([] of String).should eq({[] of String, false})
    Gori::CLI.settings_argv_for_spec(["--"]).should eq({[] of String, false})
    Gori::CLI.settings_argv_for_spec(["--edit", "--"]).should eq({[] of String, true})
  end
end

# `import` joins the same run instead of rejecting it, because there `--` carries its POSIX
# meaning: everything after it is a FILENAME.
describe "gori settings import — arguments after a `--` separator" do
  it "takes a file named past `--`" do
    # Aborted with "needs a file", so a profile whose name starts with a dash — the one case
    # `--` exists for — could not be imported at all.
    Gori::CLI.import_files_for_spec(["--", "p.json"]).should eq(["p.json"])
    Gori::CLI.import_files_for_spec(["--", "./--odd.json"]).should eq(["./--odd.json"])
  end

  it "counts a second file hidden past `--`, so the one-file guard fires" do
    # Imported a.json, discarded b.json, and reported success — defeating the `rest.size > 1`
    # guard whose whole purpose is catching a glob that matched two files.
    Gori::CLI.import_files_for_spec(["a.json", "--", "b.json"]).size.should eq(2)
    Gori::CLI.import_files_for_spec(["--", "a.json", "b.json"]).size.should eq(2)
  end

  it "still parses its own flags before the separator" do
    Gori::CLI.import_files_for_spec(["p.json", "--dry-run"]).should eq(["p.json"])
    Gori::CLI.import_files_for_spec(["--sections=network", "p.json"]).should eq(["p.json"])
  end
end

# `-o` pointing at the live settings file is data loss, not an export: the document omits every
# section at its default and both secret sections, and write_export is a plain truncate — so it
# DELETES `env` (token values) and `decoder` in place, says "wrote <path>", and exits 0.
describe "gori settings export — same-file detection for -o" do
  it "matches the same file through `..`, a relative path and a symlink" do
    dir = File.tempname("gori-cli-samefile")
    Dir.mkdir_p(File.join(dir, "home"))
    settings = File.join(dir, "home", "settings.json")
    File.write(settings, "{}")
    begin
      Gori::CLI.same_file_for_spec(settings, settings).should be_true
      Gori::CLI.same_file_for_spec(File.join(dir, "home", "..", "home", "settings.json"), settings).should be_true
      # A symlinked config directory is the same overwrite spelled differently.
      link = File.join(dir, "link")
      File.symlink(File.join(dir, "home"), link)
      Gori::CLI.same_file_for_spec(File.join(link, "settings.json"), settings).should be_true
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "does not match an ordinary export target beside it" do
    # A false positive would refuse a perfectly good export, so the negative side matters as
    # much: same directory, and a target that does not exist yet (the ordinary case).
    dir = File.tempname("gori-cli-samefile-neg")
    Dir.mkdir_p(dir)
    settings = File.join(dir, "settings.json")
    File.write(settings, "{}")
    begin
      Gori::CLI.same_file_for_spec(File.join(dir, "team-profile.json"), settings).should be_false
      Gori::CLI.same_file_for_spec(File.join(dir, "settings.json.bak"), settings).should be_false
      Gori::CLI.same_file_for_spec(File.join(dir, "nested", "settings.json"), settings).should be_false
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe "gori settings — section-name validation" do
  # Static SECTION_KEYS, never `document_keys`: a section at its factory default is absent from
  # the latter, which is how `--sections network,scan_rules` (the example in the CLI reference)
  # aborted as "unknown" on every fresh install.
  it "accepts a known section this install has no value for" do
    Gori::CLI.unknown_sections_for_spec(["network", "scan_rules"]).should be_empty
    Gori::CLI.unknown_sections_for_spec(Gori::Settings::SECTION_KEYS).should be_empty
  end

  it "names the ones gori does not know" do
    # Import used not to validate at all, so `--sections netwrok` selected nothing and reported
    # "imported 0 section(s)" with exit 0.
    Gori::CLI.unknown_sections_for_spec(["netwrok"]).should eq(["netwrok"])
    Gori::CLI.unknown_sections_for_spec(["network", "bogus", "theme"]).should eq(["bogus"])
  end
end
