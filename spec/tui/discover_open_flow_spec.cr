require "../spec_helper"
require "../support/memory_backend"

# `↵` on a Discover findings row opens the request/response that row was found with, in the
# same History detail the Sitemap's `o` opens. The run holds no bytes — the exchange went
# straight to the store when the finding landed — so the whole gesture rests on `flow_ids`
# staying index-aligned with `findings`. A drift there does not fail loudly; it opens the
# bytes of a DIFFERENT endpoint, which is the one outcome worse than opening nothing.
include Gori::Tui

private def finding(url : String) : Gori::Discover::Finding
  Gori::Discover::Finding.new(url, "GET", 200, 4_i64, "text/html",
    Gori::Discover::Source::Crawled, 1, 0.95, nil)
end

private def render(view : DiscoverView, w = 120, h = 30) : Nil
  view.render(Screen.new(MemoryBackend.new(w, h)), Rect.new(0, 0, w, h), true)
end

private def run_with(urls : Array(String)) : DiscoverRun
  run = DiscoverRun.new(urls.first, Gori::Discover::Config.new)
  urls.each { |u| run.add_finding(finding(u)) }
  run
end

describe "Discover finding → flow" do
  it "hands each finding its own flow id" do
    run = run_with(%w[http://t/a http://t/b http://t/c])
    run.flow_ids.size.should eq(3)
    run.flow_ids.should eq([nil, nil, nil])

    run.set_flow_id(0, 11_i64)
    run.set_flow_id(2, 33_i64)
    run.flow_id_at(0).should eq(11_i64)
    run.flow_id_at(1).should be_nil
    run.flow_id_at(2).should eq(33_i64)
  end

  it "ignores an id for a row that is no longer there" do
    # A re-run clears the findings while the previous run's persist batch may still be in
    # flight; the late id must not resurrect a row or raise into the drain loop.
    run = run_with(%w[http://t/a])
    run.begin_run
    run.findings.should be_empty
    run.flow_ids.should be_empty
    run.set_flow_id(0, 7_i64)
    run.flow_id_at(0).should be_nil
  end

  it "resolves the flow under the findings cursor" do
    view = DiscoverView.new
    run = run_with(%w[http://t/a http://t/b])
    run.set_flow_id(0, 11_i64)
    run.set_flow_id(1, 22_i64)
    view.add(run)
    view.focus_pane(:findings)

    view.selected_flow_id.should eq(11_i64)
    view.move(1)
    view.selected_finding.not_nil!.url.should eq("http://t/b")
    view.selected_flow_id.should eq(22_i64)
  end

  it "reports no flow for a finding whose store write never landed" do
    view = DiscoverView.new
    view.add(run_with(%w[http://t/a]))
    view.focus_pane(:findings)
    view.selected_finding.should_not be_nil
    view.selected_flow_id.should be_nil
  end

  it "has nothing to open with no findings at all" do
    view = DiscoverView.new
    view.add(DiscoverRun.new("http://t/", Gori::Discover::Config.new))
    view.focus_pane(:findings)
    view.selected_finding.should be_nil
    view.selected_flow_id.should be_nil
  end

  it "pulls the cursor back inside a re-run that found fewer endpoints" do
    # ^R empties `findings` on the run while `@fsel` lives on the view, so a cursor parked on
    # row 9 of a 10-finding run outlived a re-run that found 3: the band was drawn on nothing
    # and `selected_finding` was nil with rows plainly on screen.
    view = DiscoverView.new
    run = run_with((1..10).map { |i| "http://t/#{i}" })
    view.add(run)
    view.focus_pane(:findings)
    9.times { view.move(1) }
    view.selected_finding.not_nil!.url.should eq("http://t/10")

    run.begin_run
    3.times { |i| run.add_finding(finding("http://t/re#{i}")) }
    run.set_flow_id(2, 99_i64)
    render(view)

    view.selected_finding.not_nil!.url.should eq("http://t/re2")
    view.selected_flow_id.should eq(99_i64)
  end

  it "answers for the cursor row from either pane — `o` opens what is drawn selected" do
    view = DiscoverView.new
    run = run_with(%w[http://t/a http://t/b])
    run.set_flow_id(1, 22_i64)
    view.add(run)
    view.focus_pane(:findings)
    view.move(1)
    view.focus_pane(:runs) # ↑ back to the RUNS list — the findings cursor stays put
    view.focus.should eq(:runs)
    view.selected_flow_id.should eq(22_i64)
  end
end
