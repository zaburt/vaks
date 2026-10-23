require_relative "lib/vaks/version"

Gem::Specification.new do |spec|
  spec.name        = "vaks"
  spec.version     = Vaks::VERSION
  spec.authors     = ["Onur Küçük"]
  spec.email       = ["onur@delipenguen.net"]
  spec.summary     = "Video file conversion daemon using ffmpeg and inotify"
  spec.description = <<~DESC
    vaks watches directories for video files and converts them with ffmpeg
    according to per-directory profiles. Managed by systemd as a user service,
    controlled at runtime via the vaksctl CLI over a Unix socket.
  DESC
  spec.license     = "GPL-2.0-only"
  spec.homepage    = "https://github.com/zaburt/vaks"

  spec.required_ruby_version = ">= 4.0.0"

  spec.files = Dir["lib/**/*.rb", "bin/*", "contrib/*", "doc/**/*", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir      = "bin"
  spec.executables = %w[vaksd vaksctl]

  spec.add_dependency "rb-inotify", "~> 0.11"
  spec.add_dependency "logger"
  spec.add_dependency "ruby-dbus", "~> 0.25"
end
