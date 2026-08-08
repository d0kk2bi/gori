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

# A rule list's actions belong to the KEYMAP, not to a hand-rolled `case` in its controller.
# Four of the six deferred (Scope, Env, Host overrides, Probe rules); Rewriter and Colormarker
# hardcoded `a / ↵,e / d / x / ⇧X / s / ⇧J / ⇧K` and registered every verb with `[] of Chord`,
# so those two lists alone could not be rebound and their keys never met the `available?` gate
# the space menu uses.
describe "rule-list keys" do
  it "are real chords on the verbs, for every rule list" do
    r = Gori::Verbs.registry
    {
      "scope.add-rule", "env.add-var", "hostoverride.add-entry", "probe-rules.add",
      "colormarker.add",
    }.each do |id|
      r[id].chords.should_not be_empty
    end
  end

  it "gives Colormarker the same key set its controller used to hardcode" do
    r = Gori::Verbs.registry
    plain = ->(k : String) { Gori::Verb::Chord.new(k) }
    shift = ->(k : String) { Gori::Verb::Chord.new(k, shift: true) }
    r["colormarker.add"].chords.should contain(plain.call("a"))
    r["colormarker.edit"].chords.should contain(plain.call("e"))
    r["colormarker.edit"].chords.should contain(plain.call("enter"))
    r["colormarker.delete"].chords.should contain(plain.call("d"))
    r["colormarker.toggle"].chords.should contain(plain.call("x"))
    r["colormarker.scope"].chords.should contain(plain.call("s"))
    r["colormarker.toggle-default"].chords.should contain(shift.call("x"))
    r["colormarker.move-down"].chords.should contain(shift.call("j"))
    r["colormarker.move-up"].chords.should contain(shift.call("k"))
    # …and the menu letter now names the key. It was 'g', which matched neither the verb
    # ("Enable/disable everywhere") nor its ⇧X binding.
    r["colormarker.toggle-default"].menu_key.should eq('X')
  end
end
