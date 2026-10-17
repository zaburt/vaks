require "open3"
require "shellwords"

module Vaks
  module Ffmpeg
    # ffmpeg's human-readable stderr "stats" line (frame=... time=... speed=...)
    # is redrawn in place with '\r', not '\n', so Ruby's line-based readers
    # never see individual updates mid-encode — they only see whatever got
    # concatenated together once a real '\n' finally appears (usually only at
    # the very end). We use ffmpeg's machine-readable "-progress pipe:1" output
    # instead: clean, newline-terminated key=value pairs on their own stream,
    # updated every ~0.5s regardless of terminal/pipe.
    OUT_TIME_RE = /^out_time_us=(\d+)$/
    FPS_RE      = /^fps=(\d+\.?\d*)$/
    SPEED_RE    = /^speed=(\S+)$/

    # Build the ffmpeg argument array for a conversion.
    # Always uses array form — never passes through a shell.
    def self.build_args(input, output, profile)
      # -y: always overwrite an existing output file. Without it, -nostdin makes ffmpeg
      # abort immediately (no prompt possible) whenever a stale file from a previous
      # crashed/killed run is already sitting at the output path (e.g. in working_dir).
      args = ["ffmpeg", "-nostdin", "-y", "-i", input, "-map", "0"]
      args += ["-c:v", profile[:codec_video].to_s]    if profile[:codec_video]
      args += ["-s",   profile[:resolution].to_s]     if profile[:resolution]

      if profile[:codec_audio]
        codec = profile[:codec_audio].to_s
        if profile[:smart_audio]
          current = probe_audio_codec(input)
          codec = "copy" if current == codec.downcase
        end
        args += ["-c:a", codec]
      end

      args += ["-c:s", profile[:codec_subtitle].to_s] if profile[:codec_subtitle]
      args += profile[:extra_args].shellsplit          if profile[:extra_args]
      args << output
      args
    end

    # Probe the first audio stream codec of a file using ffprobe.
    # Returns the codec name (e.g. "aac", "ac3") or nil if unavailable.
    def self.probe_audio_codec(input)
      out, = Open3.capture2(
        "ffprobe", "-v", "error",
        "-select_streams", "a:0",
        "-show_entries", "stream=codec_name",
        "-of", "default=noprint_wrappers=1:nokey=1",
        input
      )
      codec = out.strip.downcase
      codec.empty? ? nil : codec
    rescue Errno::ENOENT
      nil
    end

    # Container duration in seconds via ffprobe, or nil if unknown/unavailable.
    def self.probe_duration(input)
      out, = Open3.capture2("ffprobe", "-v", "error", "-show_entries", "format=duration",
                            "-of", "default=noprint_wrappers=1:nokey=1", input)
      seconds = out.strip.to_f
      seconds.positive? ? seconds : nil
    rescue Errno::ENOENT
      nil
    end

    # Run ffmpeg for the given input/output/profile.
    #
    # Yields progress events as hashes:
    #   { event: :start,    pid: Integer }
    #   { event: :output,   pid: Integer, line: String }   raw stderr line, unparsed
    #   { event: :progress, pid: Integer, elapsed: Float, fps: Float|nil, speed: String|nil }
    #   { event: :done,     pid: Integer, success: Boolean, exit_code: Integer }
    #
    # nice/ionice_class/ionice_level: optional CPU/IO throttling — the ffmpeg process
    # is wrapped with `nice -n N` and/or `ionice -c CLASS -n LEVEL` when given.
    #
    # Returns true on success, false on failure.
    def self.run(input, output, profile, nice: nil, ionice_class: nil, ionice_level: nil, &on_progress)
      args = build_args(input, output, profile)

      # -nostats: silence the noisy, carriage-return-redrawn per-frame stderr
      # line now that we get progress from the pipe below — keeps stderr (and
      # therefore the live-output panel / saved error logs) to warnings and
      # real diagnostics only.
      # -progress pipe:1: machine-readable progress on its own stdout stream.
      run_args = args.dup
      run_args.insert(1, "-nostats", "-progress", "pipe:1")
      run_args = wrap_with_throttling(run_args, nice, ionice_class, ionice_level)

      Open3.popen3(*run_args) do |_stdin, stdout, stderr, wait_thr|
        pid = wait_thr.pid
        on_progress&.call(event: :start, pid: pid)

        stderr_buf = []
        fields     = {}

        progress_thread = Thread.new do
          stdout.each_line do |line|
            line = line.chomp
            case line
            when OUT_TIME_RE then fields[:elapsed] = $1.to_i / 1_000_000.0
            when FPS_RE      then fields[:fps]     = $1.to_f
            when SPEED_RE    then fields[:speed]   = $1
            when /^progress=/
              on_progress&.call(event: :progress, pid: pid, elapsed: fields[:elapsed] || 0.0,
                                 fps: fields[:fps], speed: fields[:speed])
            end
          end
        end

        stderr.each_line do |line|
          stderr_buf << line
          on_progress&.call(event: :output, pid: pid, line: line.chomp)
        end

        progress_thread.join
        status = wait_thr.value
        on_progress&.call(event: :done, pid: pid, success: status.success?, exit_code: status.exitstatus,
                          stderr: stderr_buf.join, command: Shellwords.join(args))
        status.success?
      end
    end

    # Return the ffmpeg version string, or nil if ffmpeg is not on PATH.
    def self.version
      out, = Open3.capture2("ffmpeg", "-version")
      out.lines.first&.chomp
    rescue Errno::ENOENT
      nil
    end

    # Prefixes the ffmpeg argv with `nice`/`ionice` for CPU/IO throttling when configured.
    # Falls back gracefully (skips the wrapper) if the tool isn't on PATH.
    def self.wrap_with_throttling(args, nice, ionice_class, ionice_level)
      prefix = []
      if ionice_class && command_exists?("ionice")
        prefix += ["ionice", "-c", ionice_class.to_s]
        prefix += ["-n", ionice_level.to_s] if ionice_level
      end
      if nice && command_exists?("nice")
        prefix += ["nice", "-n", nice.to_s]
      end
      prefix.empty? ? args : prefix + args
    end

    def self.command_exists?(cmd)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, cmd)) }
    end
  end
end
