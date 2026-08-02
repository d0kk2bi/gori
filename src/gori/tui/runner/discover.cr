# Discover (spider + dir-brute) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Seed a discovery run from the selected Sitemap node — offering the path subtree AND the
  # host root as start-target choices in the config popup.
  def sitemap_discover : Nil
    view = sitemap_controller.view
    ep = view.selected_endpoint
    unless ep
      @toast = "select a host or path to discover"
      return
    end
    # The origin comes from a REAL captured flow (an id fold has none of its own, so that
    # resolves to a descendant), but the scan target is the CONTAINER — on a `{uuid}` row
    # the user means "discover under /users", not "brute-force under this one uuid".
    # Both are identity on a normal node, so nothing changes off a fold.
    id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
    base = id.try { |i| @session.store.flow_row(i).try(&.url) }
    origin = base.try { |u| Discover::Url.parse(u).try { |p| Discover::Url.origin(p) } } || "https://#{ep[:host]}"
    target = view.selected_endpoint(:container).try(&.[](:target)) || ep[:target]
    open_discover_config(build_discover_seed(origin, ep[:host], target))
  end

  # Marks (#442) enrich this WITHIN one host: the config popup's start-target list becomes the
  # union of the marked flows' paths, so "mark five endpoints, then pick which to spider under"
  # works. It stays deliberately SINGLE-HOST — one popup chooses one start target from one
  # host's path list, and the header-reuse confirm it raises is nested over that popup
  # (return_to: :discover_config), so neither generalises to M hosts without either M stacked
  # popups or silently discarding the target the user picked. Multi-host marks are refused with
  # a toast and fall back to the cursor row.
  def history_discover : Nil
    ids = history_target_flow_ids
    # flow_row, not get_flow: all this needs per flow is the URL, and get_flow would pull the
    # full request+response bodies for every mark — up to a whole page after ⇧T — most of which
    # this then throws away. Only the ONE header donor below is loaded in full.
    parsed = ids.compact_map do |id|
      @session.store.flow_row(id).try { |row| Discover::Url.parse(row.url).try { |p| {id, p} } }
    end
    if parsed.empty?
      @toast = ids.empty? ? "select a flow to discover" : "flow has no discoverable URL"
      return
    end
    hosts = parsed.map { |(_, p)| p.host }.uniq!
    if hosts.size > 1
      # Narrow to the PRIMARY target's host — the cursor row when it is itself a target, else the
      # oldest mark. Not `parsed.first`: that is display order, so which host survived would flip
      # with a history_list_order change, and the toast below promises the cursor row.
      @toast = "marked flows span #{hosts.size} hosts — discover runs one host at a time"
      primary = history_controller.primary_target_flow_id
      keep = parsed.find { |(id, _)| id == primary } || parsed.first
      parsed = parsed.select { |(_, p)| p.host == keep[1].host }
    end
    donor_id, first = parsed.find { |(id, _)| id == history_controller.primary_target_flow_id } || parsed.first
    open_discover_config(build_discover_seed(Discover::Url.origin(first), first.host,
      parsed.map { |(_, p)| p.path }))
    # One donor for the reused auth/cookie headers — the confirm is nested over the config
    # popup and can't loop, so the first marked flow supplies them. This is the only full
    # detail load on this path.
    if donor = @session.store.get_flow(donor_id)
      offer_flow_headers(donor_id, donor.request_head)
    end
  end

  def discover_run : Nil
    discover_controller.discover_run
  end

  def discover_stop : Nil
    discover_controller.discover_stop
  end

  def discover_toggle_pause : Nil
    discover_controller.discover_toggle_pause
  end

  def discover_dismiss : Nil
    discover_controller.discover_dismiss
  end

  def goto_discover : Nil
    focus_tab(:target)
    target_controller.select_discover
  end
end
