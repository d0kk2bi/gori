require "../spec_helper"

# Every registered verb must be reachable from SOME keyboard surface. `sequence.export-json`
# was not: no chord, no `mnemonic:`, so `Definition#menu_key` returned nil, `SpaceMenu#open`
# filters on `menu_key`, and the palette only queries `Scope::Global`. A shipped export with
# a handler, an `ExecContext` method and no way to invoke it.
#
# The three surfaces, and the whole rule:
#   • a chord      → the keymap fires it
#   • a menu_key   → the space menu lists it (explicit `mnemonic:`, else a plain 1-char chord)
#   • Scope::Global → the palette lists it regardless
describe "verb reachability" do
  it "leaves no verb without a keyboard path" do
    unreachable = [] of String
    Gori::Verbs.registry.each do |v|
      next if v.hidden?                            # a gesture, not a listed command
      next if v.scope == Gori::Verb::Scope::Global # the palette lists these by scope alone
      next unless v.chords.empty?
      next if v.menu_key
      unreachable << v.id
    end
    unreachable.should be_empty
  end

  it "keeps a hidden verb's chord, since hidden means unlisted rather than unbound" do
    # The exemption above is only safe while `hidden: true` implies a chord — a hidden verb
    # with neither would be just as unreachable, and the check would wave it through.
    Gori::Verbs.registry.each do |v|
      v.chords.should_not be_empty if v.hidden?
    end
  end
end
