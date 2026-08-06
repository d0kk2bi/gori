# OAST out-of-band listener — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def oast_listen : Nil
    oast_controller.start_listening_action
  end

  def oast_stop : Nil
    oast_controller.stop_listening
  end

  def oast_generate : Nil
    oast_controller.generate_payload
  end

  def oast_copy : Nil
    oast_controller.copy_payload
  end

  def oast_filter : Nil
    oast_controller.start_cb_filter
  end

  # Open RESUME LISTENER over this project's persisted sessions. The open-site injects both
  # actions (↵ resume, `x` release) so the picker itself stays a dumb list, per the Overlay
  # seam — and both land back in the controller, which owns every listener.
  def oast_sessions : Nil
    rows = oast_controller.session_rows
    if rows.empty?
      @toast = "no OAST sessions yet — start one with ^R"
      return
    end
    picker = OastSessionPicker.new(rows)
    picker.on_commit = -> {
      picker.selected_row.try { |row| oast_controller.resume_session(row.session_id) }
      true
    }
    picker.on_release = ->(session_id : Int64) { oast_controller.release_session(session_id) }
    open_overlay(picker)
  end

  def oast_callback_selected? : Bool
    oast_controller.callback_selected?
  end

  # File the selected callback as an Issue, its raw interaction carried in as the notes. High
  # by default, not the form's Medium: a callback is not a suspicion — the target's own
  # infrastructure reached a server it was never given a reason to reach. Tab re-rates it.
  def oast_issue_create : Nil
    draft = oast_controller.callback_issue_draft
    unless draft
      @toast = "no callback selected"
      return
    end
    open_issue_form(IssueForm.new(draft.title, draft.host,
      severity: Store::Severity::High, notes: draft.notes))
  end

  def oast_add_provider : Nil
    oast_controller.open_add_provider
  end

  def oast_edit_provider : Nil
    oast_controller.open_edit_provider
  end

  def oast_toggle_provider : Nil
    oast_controller.toggle_provider
  end

  def oast_delete_provider : Nil
    oast_controller.delete_provider
  end

  def oast_payload_available? : Bool
    oast_controller.has_active_listener?
  end

  def oast_insert_payload : Nil
    url = oast_controller.generate_for_insert
    unless url
      @toast = "no OAST listener — start one in the OAST tab (^R)"
      return
    end
    ok = case @active_tab
         when :repeater then repeater_controller.insert_oast_payload(url)
         when :fuzzer   then fuzzer_controller.insert_oast_payload(url)
         else                false
         end
    @toast = ok ? "inserted OAST payload: #{url}" : "focus the request/template editor first"
  end

  def oast_copy_payload : Nil
    url = oast_controller.generate_for_insert
    unless url
      @toast = "no OAST listener — start one in the OAST tab (^R)"
      return
    end
    Clipboard.copy(url)
    @toast = "copied OAST payload: #{url}"
  end

  # A callback's detail is open — the gate for its read verbs.
  def oast_detail_readable? : Bool
    oast_controller.oast_detail_readable?
  end
end
