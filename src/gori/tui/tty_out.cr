module Gori::Tui
  # The device gori's own escape sequences have to reach.
  #
  # gori writes a handful of sequences itself rather than through termisu — OSC 52
  # (`Clipboard`), xterm mode 1002 (`MouseDrag`), the bell (`Notifications`) — and every
  # one of them used to go to STDOUT. That is the wrong file descriptor. Termisu draws
  # through its OWN `/dev/tty` handle (`Termisu::TTY` opens the path itself), so STDOUT
  # and the terminal only coincide when nothing has redirected stdout.
  #
  # When they diverge the failure is silent and total: the TUI still renders (termisu is
  # unaffected), the copy toast still reads "copied GET / to clipboard (122b)", and the
  # OSC 52 lands in whatever stdout points at. Measured by running the TUI under a
  # redirect — zero `ESC]52` bytes reached the terminal, the whole sequence turned up in
  # the file, and `ESC[?1002h` went with it, which takes drag selection down too (press
  # and release survive because termisu owns modes 1000/1006).
  #
  # So resolve the controlling terminal the way termisu does instead of trusting fd 1.
  module TtyOut
    private PATH = "/dev/tty"

    @@io : IO? = nil
    @@resolved = false

    # The tty to write escapes to, opened once.
    #
    # UNBUFFERED on purpose. This is a second stream onto the device termisu already
    # writes to, and a second *buffer* there is precisely the hazard this module exists
    # to remove: these are whole sequences emitted between renders, so they must land
    # when written rather than sit waiting for a flush that another writer's output
    # could get ahead of.
    #
    # Falls back to STDOUT when there is no controlling terminal to open. That covers
    # specs and any headless caller that reaches a TUI helper; in a real TUI session
    # termisu would have failed to start long before this could matter.
    def self.io : IO
      unless @@resolved
        @@resolved = true
        @@io = open_tty
      end
      @@io || STDOUT
    end

    private def self.open_tty : IO?
      f = File.open(PATH, "w")
      f.sync = true
      f
    rescue
      nil
    end
  end
end
