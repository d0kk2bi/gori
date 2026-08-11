require "json"
require "./bind_address"
require "./durable_file"
require "./paths"

module Gori
  # Per-project capture sidecar written by the session that holds the capture lock.
  # The project picker reads it (together with a flock probe) to show the live bind
  # address of a project opened in another gori instance. The file alone is NOT
  # authoritative — only a held `.capture.lock` means the project is live.
  class CaptureStatus
    STATUS_FILE = ".capture.status"

    record Status, host : String, port : Int32, listening : Bool

    def self.path(dir : String) : String
      File.join(dir, STATUS_FILE)
    end

    def self.write(dir : String, host : String, port : Int32, listening : Bool) : Nil
      # `Paths.ensure_dir`, not a bare `Dir.mkdir_p`: this can be the call that creates a
      # project directory, and every gori dir is owner-only 0700 (see Paths::DIR_MODE) —
      # the captured traffic DB lands in here. A plain mkdir_p leaves it at the umask,
      # world-traversable on a shared host.
      #
      # `tighten: false` because this directory is not always gori's. `Project#dir` is
      # `File.dirname(db_path)`, so a `--db /shared/team/traffic.db` project borrows an
      # arbitrary parent (project.cr says so); chmod'ing THAT to 0700 would strip group
      # access from a directory gori merely found. A dir gori creates still lands at 0700.
      Paths.ensure_dir(dir, tighten: false)
      payload = {
        "host"      => host,
        "port"      => port,
        "listening" => listening,
      }.to_json
      # 0644 is the fallback for a file that does not exist yet; this marker holds a bind
      # address, not a secret, and the 0700 dir above is what keeps it private.
      DurableFile.write(path(dir), payload, perm: File::Permissions.new(0o644))
    end

    def self.read(dir : String) : Status?
      parse_file(path(dir))
    end

    # Parse a status file; nil on missing, corrupt, or partial writes.
    private def self.parse_file(p : String) : Status?
      return nil unless File.exists?(p)
      json = JSON.parse(File.read(p))
      Status.new(
        host: json["host"].as_s,
        port: json["port"].as_i,
        listening: json["listening"].as_bool,
      )
    rescue
      nil
    end

    def self.clear(dir : String) : Nil
      File.delete?(path(dir))
    end

    # Human-friendly bind label for the picker. Terse: this rides inside a project row's
    # chip, so it takes the address without BindAddress's "(all interfaces)" note — the
    # address itself is identical to every other surface's.
    def self.format_endpoint(host : String, port : Int32) : String
      BindAddress.display(host, port, terse: true)
    end
  end
end
