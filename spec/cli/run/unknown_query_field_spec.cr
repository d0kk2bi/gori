require "../../spec_helper"

# `CLI::Run.unknown_query_field_error` — the seam behind `refuse_unknown_query_fields`, which
# the three QL-taking `gori run` surfaces (history, sitemap, probe) call.
#
# The failure it exists for: `QL`'s `field_cond` free-texts the WHOLE token of a field name it
# does not implement, on purpose — so `gori run history -q 'methd:GET'` searched method/host/path
# for the literal string "methd:GET", found nothing, and answered `no flows match "methd:GET"`.
# That reads as "this project is empty", not as "you spelled `method` wrong", and a script gets
# an exit status of 0 with an empty list. Nothing anywhere said the field name was not a field.
#
# `abort` is not spec-able, which is why the DECISION and the MESSAGE were split into this
# function. Everything below drives it directly.

describe Gori::CLI::Run do
  describe ".unknown_query_field_error" do
    it "proceeds on no query at all, and on a query whose every field is real" do
      Gori::CLI::Run.unknown_query_field_error("history", nil).should be_nil
      Gori::CLI::Run.unknown_query_field_error("history", "method:GET").should be_nil
      Gori::CLI::Run.unknown_query_field_error("history", "host:acme status:>=500 dur:>1.5s").should be_nil
    end

    # The whole ticket, on each of the three surfaces that take a QL. The command name is a
    # parameter rather than baked in, so a copy-pasted message cannot name the wrong one.
    it "refuses an unrecognized field on history, sitemap and probe alike, naming it" do
      {"history", "sitemap", "probe"}.each do |cmd|
        msg = Gori::CLI::Run.unknown_query_field_error(cmd, "methd:GET").not_nil!
        msg.should start_with("gori run #{cmd}: unknown query field `methd:`")
        msg.should contain("did you mean `method:`?")
        msg.should contain("--lenient")
      end
    end

    # `ext` is within three edits of `dur` and of `url`; naming either would be inventing an
    # intent. So the line spends its budget on the field list instead of on a guess.
    it "lists the fields rather than guessing when nothing is close enough" do
      msg = Gori::CLI::Run.unknown_query_field_error("history", "ext:js").not_nil!
      msg.should contain("unknown query field `ext:`")
      msg.should contain("QL has no such field")
      msg.should_not contain("did you mean")
      Gori::QL::FIELDS.each { |f| msg.should contain(f) }
    end

    # Echoed with the operator it was WRITTEN with: a `~` typo must not come back spelled `:`,
    # or the suggested fix is a term the operator did not ask for.
    it "keeps the regex operator in both the bad field and the suggestion" do
      msg = Gori::CLI::Run.unknown_query_field_error("history", "bdy~secret").not_nil!
      msg.should contain("`bdy~`")
      msg.should contain("`body~`")
    end

    # `QL.known_field?`, not `QL::FIELDS.includes?`: QL ACCEPTS spellings it does not OFFER, and
    # refusing one would reject a query QL compiles perfectly. See `QL::FIELD_ALIASES`.
    it "accepts every alias QL accepts but does not offer" do
      Gori::QL::FIELD_ALIASES.each_key do |alias_name|
        Gori::CLI::Run.unknown_query_field_error("history", "#{alias_name}:x").should be_nil
      end
    end

    # A bare word is free text by design (`login` searches method/host/path) — it names no
    # field at all, so there is no field to refuse.
    it "leaves bare-word free text alone" do
      Gori::CLI::Run.unknown_query_field_error("history", "login").should be_nil
      Gori::CLI::Run.unknown_query_field_error("history", "host:acme login").should be_nil
      Gori::CLI::Run.unknown_query_field_error("history", ":leading-colon").should be_nil
    end

    # One field per line: the operator re-runs either way, and the suggestion is the half that
    # ends the round trip.
    it "names the first unknown field when a query has several" do
      Gori::CLI::Run.unknown_query_field_error("history", "hsot:a methd:GET")
        .not_nil!.should contain("`hsot:`")
    end

    # A term QL DROPS (a bad numeric on a REAL field) is `warn_query_terms`' job, not this one:
    # it broadens the result, which leaves the operator something to look at.
    it "does not claim a real field with an uncompilable value is unknown" do
      Gori::CLI::Run.unknown_query_field_error("history", "size:>bogus").should be_nil
      Gori::CLI::Run.unknown_query_field_error("history", "proto:zzz").should be_nil
    end
  end

  describe ".refuse_unknown_query_fields" do
    # `abort` would take the spec process with it, so surviving the call IS the assertion:
    # --lenient restores the old free-text behaviour for a script that relied on it.
    it "does not refuse under --lenient" do
      Gori::CLI::Run.refuse_unknown_query_fields("history", "methd:GET", true)
      Gori::CLI::Run.refuse_unknown_query_fields("history", nil, false)
      Gori::CLI::Run.refuse_unknown_query_fields("history", "method:GET", false)
    end
  end
end

# The suggestion itself lives in QL, beside `known_field?`, so the candidate pool cannot drift
# from the pool that decides what is known in the first place.
describe Gori::QL do
  describe ".suggest_field" do
    it "has nothing to suggest for a name QL already implements" do
      Gori::QL.suggest_field("method").should be_nil
      Gori::QL.suggest_field("res.body").should be_nil # an alias is known too
      Gori::QL.suggest_field("").should be_nil
    end

    # Prefix BEFORE edit distance. `meth` is two edits from `method` AND two from `path`, so
    # distance alone answers `path` — the wrong half of the query.
    it "prefers an unambiguous prefix over the equally-distant wrong answer" do
      Gori::QL.suggest_field("meth").should eq("method")
      Gori::QL.suggest_field("stat").should eq("status")
      Gori::QL.suggest_field("resp.b").should eq("resp.body")
      Gori::QL.suggest_field("m").should eq("method") # one letter, still only one field
    end

    # `s` prefixes `scheme` `status` `size` `stub`; picking one of four is a coin flip printed
    # as advice, so an ambiguous prefix falls through to distance and comes back empty.
    it "says nothing rather than picking one of an ambiguous prefix's candidates" do
      Gori::QL.suggest_field("s").should be_nil
      Gori::QL.suggest_field("re").should be_nil
    end

    # A transposition costs two edits, which Levenshtein's own default tolerance refuses.
    it "reaches a transposition and a dropped letter" do
      Gori::QL.suggest_field("hsot").should eq("host")
      Gori::QL.suggest_field("methd").should eq("method")
      Gori::QL.suggest_field("bdy").should eq("body")
      Gori::QL.suggest_field("resp.bdy").should eq("resp.body")
    end

    it "guesses nothing when nothing is close" do
      Gori::QL.suggest_field("ext").should be_nil
      Gori::QL.suggest_field("xyzzy").should be_nil
      Gori::QL.suggest_field("zz").should be_nil
    end
  end
end
