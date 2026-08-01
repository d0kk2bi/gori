require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_area"
require "../discover"

module Gori::Tui
  # The custom-headers editor for a Discover run: a plain multi-line text editor,
  # one "Name: Value" per line. Opened from the Discover config popup's headers row;
  # esc saves the parsed headers and returns to the popup.
  # Host/Connection are always emitted by the engine, so entering them here is a
  # no-op (dropped on parse).
  #
  # A SUB-EDITOR on the Overlay seam (see overlay.cr): it has no cancel path at all, so
  # both esc and click-away commit, and the injected closure writes the parsed headers
  # back onto the Discover popup and re-opens it.
  #
  # A line gori will NOT send is a refusal, not a drop. `Headers.parse_lines` used to be
  # called here with its `rejected` out-collector omitted, so a value carrying CR/LF — a
  # request-splitting primitive, correctly refused — vanished with no word: the overlay
  # said `custom headers: 1 set`, 284 probes went out with ZERO carrying `Authorization`,
  # and the run reported `1 endpoint`. An authenticated sweep that runs unauthenticated
  # and reports "found nothing" over the whole authenticated surface is the worst way this
  # can fail, so esc now REFUSES to close while a line is unusable and names it. There is
  # no trap: deleting or fixing the line always resolves it, and a blank line is not a
  # header anyone asked for (parse_lines skips those without reporting them).
  class DiscoverHeadersOverlay < Overlay
    def initialize(headers : Array({String, String}))
      text = headers.map { |name, value| "#{name}: #{value}" }.join("\n")
      @editor = TextArea.new(text)
      @refused = nil.as(String?)
    end

    # Current headers parsed from the editor buffer.
    def headers : Array({String, String})
      Discover::Headers.parse_lines(@editor.text.split('\n'))
    end

    # The lines `parse_lines` will not turn into headers, in buffer order.
    def rejected_lines : Array(String)
      # NB: not `out` — that is a Crystal keyword and a bare `out` argument is parsed as
      # an out-parameter declaration, not as this local.
      rejected = [] of String
      Discover::Headers.parse_lines(@editor.text.split('\n'), rejected)
      rejected
    end

    # The refusal to render, or nil when every non-blank line is a usable header.
    # Recomputed on every commit attempt, so fixing the line clears it.
    def refusal : String?
      first = rejected_lines.first?
      return nil unless first
      name = first.partition(':')[0].strip
      name = first.strip if name.empty?
      name = "#{name[0, 39]}…" if name.size > 40
      "#{name.inspect} will not be sent — a header value may not contain CR or LF, " \
      "and a name must be an RFC 7230 token. Fix or delete the line."
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::DiscoverHeaders
    end

    def title : String
      "CUSTOM HEADERS"
    end

    def hint : String
      "one header per line · Host/Connection ignored · esc saves & closes"
    end

    # There is nothing to cancel INTO — the user is still inside the Discover popup — so a
    # click outside the card saves exactly like esc, which is what the shell did before.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      (box.nil? || !box.contains?(mx, my)) ? try_commit : :stay
    end

    # esc = save & close (:commit); every other key edits the buffer (:stay).
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape? then return try_commit
      when key.up?     then @editor.move(-1, 0)
      when key.down?   then @editor.move(1, 0)
      else                  edit(ev)
      end
      :stay
    end

    # Close only when every non-blank line is a header gori will actually put on the wire;
    # otherwise stay open with the refusal on the hint row.
    private def try_commit : Symbol
      @refused = refusal
      @refused ? :stay : :commit
    end

    # ⏎ inserts a new header line; the rest are the usual TextArea editing/caret keys.
    # Any edit retracts a standing refusal — it is re-derived on the next commit attempt,
    # so the red line can never outlive the line it was about.
    private def edit(ev : Termisu::Event::Key) : Nil
      @refused = nil
      key = ev.key
      case
      when key.enter?     then @editor.insert_newline
      when key.backspace? then @editor.backspace
      when key.delete?    then @editor.delete
      when key.left?      then @editor.move(0, -1)
      when key.right?     then @editor.move(0, 1)
      when key.home?      then @editor.home
      when key.end?       then @editor.end_of_line
      else
        ch = ev.char || key.to_char
        @editor.insert(ch) if ch && !ev.ctrl? && !ev.alt?
      end
    end

    def set_preedit(text : String) : Nil
      @editor.set_preedit(text)
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 6, 64}.min
      h = {area.h - 4, 16}.min
      return nil if w < 34 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "headers editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      # bg: Theme.bg (not the card default panel) so the embedded editor, which paints
      # on Theme.bg, doesn't two-tone against the card interior.
      Frame.card(screen, box, "CUSTOM HEADERS", bg: Theme.bg, border: Theme.border_focus)
      top = box.y + 1
      hintline = box.bottom - 2
      editor = Rect.new(box.x + 2, top, box.w - 4, {hintline - top, 1}.max)
      if @editor.line_count == 1 && @editor.text.empty?
        screen.text(editor.x, editor.y, "one header per line — e.g. Authorization: Bearer …", Theme.muted, Theme.bg, width: editor.w)
        screen.cursor(editor.x, editor.y)
      else
        @editor.render(screen, editor, cursor: true)
      end
      if refused = @refused
        screen.text(box.x + 2, hintline, refused, Theme.red, Theme.bg, width: box.w - 4)
      else
        screen.text(box.x + 2, hintline, "one per line · Host/Connection ignored · esc saves & closes", Theme.muted, Theme.bg, width: box.w - 4)
      end
    end
  end
end
