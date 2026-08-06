require "../spec_helper"

describe Gori::Tui::TtyOut do
  # The bug this module exists for: gori's own escapes (OSC 52, mode 1002, the bell) went
  # to STDOUT while termisu draws through its own `/dev/tty` handle. Under a redirect the
  # TUI rendered fine, the copy toast still read "copied ... (122b)", and zero `ESC]52`
  # bytes reached the terminal. So the one thing to pin is that the default sink is
  # resolved independently of fd 1.
  it "does not resolve to STDOUT when a controlling terminal is available" do
    io = Gori::Tui::TtyOut.io
    # Specs may run with no `/dev/tty` (CI), where falling back to STDOUT is correct and
    # the assertion is vacuous. When there IS one, the sink must not be fd 1.
    if File.exists?("/dev/tty") && (probe = (File.open("/dev/tty", "w") rescue nil))
      probe.close
      io.should_not be(STDOUT)
    else
      io.should be(STDOUT)
    end
  end

  it "returns the same IO on every call (opened once, not per copy)" do
    Gori::Tui::TtyOut.io.should be(Gori::Tui::TtyOut.io)
  end

  # Unbuffered: this is a second stream onto the device termisu already writes to, and a
  # second buffer there is the hazard the module removes.
  it "writes through immediately rather than buffering" do
    io = Gori::Tui::TtyOut.io
    io.as?(File).try(&.sync?.should be_true)
  end
end
