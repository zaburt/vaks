require "fileutils"
require "socket"
require "json"

module Vaks
  class SocketServer
    def initialize(socket_path:, queue:, in_flight:, pending_jobs:, pid_map:, mutex:, watcher:, logger:, config: nil, history: nil, control: nil, durations: nil, on_drain: nil, on_config: nil)
      @socket_path  = socket_path
      @queue        = queue
      @in_flight    = in_flight
      @pending_jobs = pending_jobs
      @pid_map      = pid_map
      @mutex        = mutex
      @watcher      = watcher
      @logger       = logger
      @config       = config
      @history      = history
      @control      = control
      @durations    = durations
      @on_drain     = on_drain
      @on_config    = on_config
    end

    def start
      File.delete(@socket_path) if File.exist?(@socket_path)
      @server = UNIXServer.new(@socket_path)
      File.chmod(0o600, @socket_path)
      @thread = Thread.new { accept_loop }
      @logger.info "Socket: #{@socket_path}"
    end

    def stop
      @server&.close rescue nil
      File.delete(@socket_path) if File.exist?(@socket_path) rescue nil
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        Thread.new(client) { |c| handle(c) }
      end
    rescue IOError, Errno::EBADF
      # server was closed, normal shutdown
    end

    def handle(client)
      line = client.gets&.chomp
      return unless line

      request  = JSON.parse(line)
      response = dispatch(request)
      client.puts(JSON.generate(response))
    rescue JSON::ParserError => e
      client.puts(JSON.generate(error: "invalid JSON: #{e.message}")) rescue nil
    rescue => e
      @logger.error "Socket handler error: #{e.message}"
      client.puts(JSON.generate(error: e.message)) rescue nil
    ensure
      client.close rescue nil
    end

    def dispatch(req)
      case req["cmd"]
      when "status"        then cmd_status
      when "queue"         then cmd_queue
      when "queue-reorder"  then cmd_queue_reorder(req["paths"])
      when "stop-job"      then cmd_stop_job(req["path"], req["all"])
      when "pause"         then { ok: true, paused: @control.pause(path: req["path"], all: !!req["all"]) }
      when "unpause"       then { ok: true, continued: @control.unpause }
      when "resume"        then cmd_resume
      when "power"         then cmd_power(req["action"])
      when "flush-queue"   then cmd_flush_queue
      when "drain"         then cmd_drain
      when "watch-list"    then cmd_watch_list
      when "watch-toggle"  then cmd_watch_toggle(req["path"], req["enabled"])
      when "job-output"    then cmd_job_output(req["path"])
      when "config"        then cmd_config(req)
      when "history"       then cmd_history
      when "retry-job"     then cmd_retry_job(req["path"])
      else { error: "unknown command: #{req["cmd"].inspect}" }
      end
    end

    # --- command handlers ---

    def cmd_status
      running = @mutex.synchronize do
        @pid_map.map do |path, info|
          { path: path }.merge(info.reject { |k, _| k == :output }.transform_keys(&:to_s))
        end
      end
      running.each { |j| j[:duration] = @durations&.get(j[:path]) }
      { running: running, queued: @queue.length, watches: @watcher.watched_paths.length,
        stopped: @control.stopped?, paused: @control.paused?, after_action: @control.after, power_error: @control.power_error,
        config: { workers: @config&.workers } }
    end

    def cmd_queue
      order = @queue.snapshot.map(&:path)
      jobs  = @mutex.synchronize do
        @pending_jobs.map do |j|
          { path: j.path, watch: File.basename(j.watch_path), priority: j.priority }
        end
      end
      jobs.each { |j| j[:duration] = @durations&.get(j[:path]) }
      jobs.sort_by! { |j| order.index(j[:path]) || order.length }
      { queued: jobs.length, jobs: jobs }
    end

    def cmd_queue_reorder(paths)
      return { error: "paths must be an array" } unless paths.is_a?(Array)
      @queue.reorder!(paths, id_for: ->(job) { job.path })
      { ok: true }
    end

    # Kills ffmpeg immediately (SIGKILL) and holds the queue until "resume".
    def cmd_stop_job(path, all)
      { ok: true, killed: @control.stop(path: path, all: !!all) }
    end

    def cmd_resume
      @control.resume
      { ok: true }
    end

    def cmd_power(action)
      return { error: "action must be one of: #{Control::AFTER_ACTIONS.join(", ")}" } unless @control.set_after(action)
      { ok: true, after_action: action.to_s }
    end

    def cmd_flush_queue
      flushed = 0
      loop do
        job = @queue.pop(true)
        next if job == :stop
        @mutex.synchronize do
          @in_flight.delete(job.path)
          @pending_jobs.delete(job)
        end
        flushed += 1
      end
    rescue ThreadError
      # queue empty
    ensure
      return { ok: true, flushed: flushed }
    end

    def cmd_drain
      @on_drain&.call
      { ok: true }
    end

    def cmd_watch_list
      { watches: @watcher.watched_configs }
    end

    def cmd_watch_toggle(path, enabled)
      return { error: "path required" } unless path
      ok = @config&.set_watch_enabled(path, !!enabled)
      ok ? { ok: true } : { error: "watch not found: #{path}" }
    end

    def cmd_job_output(path)
      return { error: "path required" } unless path
      output = @mutex.synchronize { @pid_map[path]&.fetch(:output, [])&.dup }
      return { error: "job not running: #{path}" } unless output
      { path: path, output: output }
    end

    def cmd_config(req)
      return { error: "config updates unavailable" } unless @on_config
      @on_config.call(req.reject { |k, _| k == "cmd" })
    end

    # Recently completed/failed jobs with duration and size saved (compression ratio),
    # plus aggregate stats (total processed, space saved, failed count).
    def cmd_history
      return { error: "history unavailable" } unless @history
      { events: @history.to_a, stats: @history.stats }
    end

    # Moves a previously-failed job's file from its watch's error_dir back into the
    # watch path, re-triggering inotify pickup so it's retried like a freshly-added file.
    def cmd_retry_job(path)
      return { error: "path required" } unless path

      wc = @watcher.watched_configs.find { |w| path.start_with?(w["path"] + "/") }
      return { error: "no watch found for #{path}" } unless wc

      basename  = File.basename(path)
      error_dir = wc["error_dir"]
      candidate = File.join(error_dir, basename)
      return { error: "no failed file found for #{basename} in #{error_dir}" } unless File.exist?(candidate)

      FileUtils.mv(candidate, path, force: true)
      { ok: true, retried: path }
    rescue => e
      { error: e.message }
    end
  end
end
