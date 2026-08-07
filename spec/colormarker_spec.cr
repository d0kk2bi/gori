require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-colormarker", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# The global rule library is process-wide state (Settings), so every example that writes it
# restores what it found — `Colormarker.load` merges it into EVERY project's rule list.
private def with_globals(&)
  before = Gori::Settings.colormarker_rules
  counter = Gori::Settings.colormarker_next_rule_id
  begin
    Gori::Settings.colormarker_rules = [] of Gori::Settings::ColormarkerRule
    Gori::Settings.colormarker_next_rule_id = 1_i64
    yield
  ensure
    Gori::Settings.colormarker_rules = before
    Gori::Settings.colormarker_next_rule_id = counter
  end
end

private def row(id : Int64 = 1_i64, method : String = "GET", host : String = "acme.test",
                target : String = "/", scheme : String = "https", status : Int32? = 200,
                content_type : String? = "text/html")
  Gori::Store::FlowRow.new(id, 0_i64, scheme, method, host, 443, target, status, 0_i64,
    Gori::Store::FlowState::Complete, content_type: content_type)
end

private RED    = Gori::Store::MarkerColor::Red
private BLUE   = Gori::Store::MarkerColor::Blue
private YELLOW = Gori::Store::MarkerColor::Yellow
private FULL   = Gori::Store::MarkerStyle::Full
private STRIP  = Gori::Store::MarkerStyle::Strip
private GLOBAL = Gori::Store::RuleScope::Global

describe Gori::Colormarker do
  describe "#match" do
    # The single claim that separates a colour rule from a rewrite rule: rewrite rules
    # COMPOSE, colour rules RESOLVE. The loser must contribute NOTHING — not its colour and
    # not its style, which is why the assertion checks both.
    it "resolves the FIRST matching rule and never consults the rest" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("status:5xx", RED, FULL, "first")
          cm.add("host:acme", BLUE, STRIP, "second")

          hit = cm.match(row(status: 500))
          hit.should_not be_nil
          hit.not_nil!.name.should eq("first")
          hit.not_nil!.color.should eq(RED)
          hit.not_nil!.style.should eq(FULL)

          # a row only the second rule matches still resolves
          cm.match(row(status: 200)).not_nil!.name.should eq("second")
        end
      end
    end

    it "applies global rules before project rules" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", BLUE, STRIP, "project rule")
          cm.add("host:acme", RED, FULL, "standing policy", scope: GLOBAL)

          cm.rules.map(&.scope).should eq([GLOBAL, Gori::Store::RuleScope::Project])
          # Both match; the global one wins, because a standing policy outranks a local layer.
          cm.match(row).not_nil!.name.should eq("standing policy")
        end
      end
    end

    it "skips a disabled rule and falls through to the next" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL, "off")
          cm.add("host:acme", BLUE, FULL, "on")
          cm.toggle(cm.rules.first.id).should be_true
          cm.match(row).not_nil!.name.should eq("on")
        end
      end
    end

    it "matches nothing when no rule is enabled" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.active?.should be_false
          cm.match(row).should be_nil
          cm.add("host:acme", RED, FULL)
          cm.active?.should be_true
        end
      end
    end

    # `Subject.payload` is always nil for a captured row, so a `body:` term answers false and
    # the rule paints nothing. Tolerated (it is a legal condition) but ADVISED against, and the
    # advice is what an operator actually sees.
    it "never matches a `body:` term, and says so" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("body:secret", RED, FULL)
          cm.match(row).should be_nil
          Gori::Colormarker.advise("body:secret").first.should contain("`body:` never matches here")
        end
      end
    end

    # An in-flight row has no status yet. This is the case History's per-row memo has to evict
    # on `:updated`, so the engine half of it is pinned here.
    it "does not match a status rule until the response lands" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("status:>=500", RED, FULL)
          cm.match(row(status: nil)).should be_nil
          cm.match(row(status: 503)).should_not be_nil
        end
      end
    end

    # The Interceptor gates WebSocket subjects behind an explicit un-negated `proto:ws`, because
    # HOLDING a socket carrying tens of messages a second is unrecoverable. PAINTING one is not,
    # so that gate must not be copied over: `host:acme` colours a WS row like any other.
    it "paints a WebSocket row without an explicit proto:ws" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL)
          ws = row(status: 101, content_type: nil)
          cm.match(ws, Gori::Proto::Kind::Ws).should_not be_nil
        end
      end
    end
  end

  describe "validation" do
    # `InterceptFilter.new` never raises, so every refusal has to be made explicitly — and each
    # of these would otherwise fail SILENTLY rather than loudly.
    it "refuses a condition that would paint every row" do
      Gori::Colormarker.unusable_reason("").should eq("enter a condition")
      # a term with an empty value is DROPPED, and an emptied query matches everything
      Gori::Colormarker.unusable_reason("host:").should eq("this condition matches every flow")
      Gori::Colormarker.unusable_reason("host:acme").should be_nil
    end

    # History QL has these; InterceptFilter does not, and `parse_term` free-texts an unknown
    # field — so `size:>10000` would become a literal substring search over method/host/target
    # and the rule would never fire, with no error anywhere.
    it "refuses a QL field this backend does not implement" do
      %w[size header dur url stub reqsize].each do |field|
        reason = Gori::Colormarker.unusable_reason("#{field}:1")
        reason.should_not be_nil
        reason.not_nil!.should contain("unknown field `#{field}:`")
      end
      Gori::Colormarker.unknown_fields("host:a AND size:1 OR dur:2").should eq(["size", "dur"])
      # `~` is a QL operator this backend does not accept as a separator, so `host~x` is free
      # text here — complaining about an unknown FIELD would be the wrong diagnosis.
      Gori::Colormarker.unknown_fields("host~x").should be_empty
    end

    it "refuses to create a rule with an unusable condition" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("", RED, FULL).should be_false
          cm.add("host:", RED, FULL).should be_false
          cm.rules.should be_empty
        end
      end
    end

    # The parser is deliberately MORE tolerant than creation: `InterceptFilter::EMPTY` matches
    # everything, so an empty condition on disk is a legal (if unwise) "paint every row" rule,
    # and dropping it would delete a rule its author can see in their own file.
    it "preserves an empty condition already on disk" do
      with_globals do
        with_store do |store|
          Gori::Settings.colormarker_rules = [
            Gori::Settings::ColormarkerRule.new(1_i64, true, "everything", "", "red", "full"),
          ]
          cm = Gori::Colormarker.load(store)
          cm.rules.size.should eq(1)
          cm.match(row).not_nil!.name.should eq("everything")
        end
      end
    end
  end

  describe "rule scope" do
    it "toggles a global rule per project without touching its default" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL, scope: GLOBAL)
          id = cm.rules.first.id

          cm.toggle(id, GLOBAL).should be_true
          cm.rules.first.enabled?.should be_false
          cm.rules.first.overridden?.should be_true
          # the LIBRARY still says on — only this project disagrees
          Gori::Settings.colormarker_rules.first.enabled.should be_true
          store.colormarker_overrides[id].should be_false

          # Toggling back AGREES with the default, so the override is dropped rather than
          # pinned — this project follows a later change to the default again.
          cm.toggle(id, GLOBAL).should be_true
          cm.rules.first.enabled?.should be_true
          cm.rules.first.overridden?.should be_false
          store.colormarker_overrides.should be_empty
        end
      end
    end

    it "flips the global default for projects that have not overridden it" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL, scope: GLOBAL)
          id = cm.rules.first.id
          cm.toggle_default(id).should be_true
          cm.rules.first.enabled?.should be_false
          cm.rules.first.overridden?.should be_false
          cm.active?.should be_false

          # A project rule has no default to flip — and it takes the SCOPE to know that. Both
          # stores count ids from 1, so this project rule is ALSO #1: a bare-id version would
          # find the global rule instead and flip it in every other project, reporting success.
          cm.add("host:x", BLUE, FULL)
          local = cm.rules.last
          local.scope.project?.should be_true
          local.id.should eq(id) # the collision this guard exists for
          cm.toggle_default(local.id, local.scope).should be_false
          cm.rules.first.enabled?.should be_false # the global default was not touched again
        end
      end
    end

    it "moves a rule between scopes, keeping its fields and its state here" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", BLUE, STRIP, "local")
          rule = cm.rules.first
          cm.set_scope(rule, GLOBAL).should be_true

          store.color_rules.should be_empty
          Gori::Settings.colormarker_rules.size.should eq(1)
          moved = cm.rules.first
          moved.scope.should eq(GLOBAL)
          moved.name.should eq("local")
          moved.color.should eq(BLUE)
          moved.style.should eq(STRIP)
          # the same scope is not a move
          cm.set_scope(moved, GLOBAL).should be_false
        end
      end
    end

    it "drops this project's override when the global rule is deleted" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL, scope: GLOBAL)
          id = cm.rules.first.id
          cm.toggle(id, GLOBAL).should be_true
          store.colormarker_overrides.should_not be_empty

          cm.remove(id, GLOBAL).should be_true
          store.colormarker_overrides.should be_empty
        end
      end
    end

    # Order is the rule set's MEANING here, not a tiebreak — so the assertion is not "the list
    # reordered" but "a different rule now paints the row".
    it "reorders within a scope, changing which rule wins" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL, "first")
          cm.add("host:acme", BLUE, FULL, "second")
          cm.match(row).not_nil!.name.should eq("first")

          second = cm.rules.last
          cm.move(second.id, -1).should be_true
          cm.match(row).not_nil!.name.should eq("second")
          # an edge of its own block does not move
          cm.move(second.id, -1).should be_false
        end
      end
    end

    it "never reorders across the scope boundary" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:a", RED, FULL, scope: GLOBAL)
          cm.add("host:b", BLUE, FULL)
          # the only global rule cannot move down into the project block
          cm.move(cm.rules.first.id, 1, GLOBAL).should be_false
          cm.rules.map(&.scope).should eq([GLOBAL, Gori::Store::RuleScope::Project])
        end
      end
    end
  end

  describe "the render-path contract" do
    # The performance claim, made testable: `InterceptFilter.new` walks FilterAst, and doing
    # that once per row per FRAME is the failure this design exists to prevent. A future
    # refactor that moves compilation onto the render path must fail HERE, not in a frame
    # budget nobody measures.
    it "compiles each condition once per edit, not once per match" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL)
          rev = cm.revision
          200.times { cm.match(row) }
          cm.revision.should eq(rev) # matching neither recompiles nor re-snapshots
        end
      end
    end

    # `reload` rides the TUI's data_version poll (~1/sec during capture). If an unchanged rule
    # set bumped the revision, History would throw away its per-row memo every tick.
    it "does not bump the revision when nothing changed" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL)
          rev = cm.revision
          5.times { cm.reload }
          cm.revision.should eq(rev)
          cm.add("host:other", BLUE, FULL)
          cm.revision.should be > rev
        end
      end
    end

    it "reports whether History must reserve its swatch column" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.strip_active?.should be_false
          cm.add("host:acme", RED, FULL)
          cm.strip_active?.should be_false # a full-row rule needs no column
          cm.add("host:cdn", BLUE, STRIP)
          cm.strip_active?.should be_true
          cm.toggle(cm.rules.last.id).should be_true
          cm.strip_active?.should be_false # disabling the only strip rule releases it
        end
      end
    end
  end

  describe ".summary" do
    it "renders a rule the same way every surface does" do
      unnamed = Gori::Store::ColorRule.new(1_i64, true, "status:5xx", RED, FULL)
      Gori::Colormarker.summary(unnamed).should eq("red full: status:5xx")
      named = Gori::Store::ColorRule.new(2_i64, true, "host:cdn", YELLOW, STRIP, "noise")
      Gori::Colormarker.summary(named).should eq("yellow strip: noise — host:cdn")
    end
  end
end
