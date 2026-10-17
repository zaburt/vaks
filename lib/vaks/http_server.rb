require "openssl"
require "socket"
require "json"
require "uri"
require "fileutils"

module Vaks
  class HttpServer
    def initialize(host:, port:, token: nil, queue:, in_flight:, pending_jobs:,
                   pid_map:, mutex:, watcher:, config:, logger:, history: nil, control: nil, durations: nil, on_drain: nil, on_config: nil)
      @host         = host
      @port         = port
      @token        = token
      @queue        = queue
      @in_flight    = in_flight
      @pending_jobs = pending_jobs
      @pid_map      = pid_map
      @mutex        = mutex
      @watcher      = watcher
      @config       = config
      @logger       = logger
      @history      = history
      @control      = control
      @durations    = durations
      @on_drain     = on_drain
      @on_config    = on_config
      @sse_clients  = []
      @sse_mutex    = Mutex.new

      # Auth rate-limiting: tracks failed-auth timestamps and temporary blocks per client IP.
      @rl_mutex        = Mutex.new
      @failed_attempts = Hash.new { |h, k| h[k] = [] }
      @blocked_until   = {}
      @audit_path      = @config&.log_dir ? File.join(@config.log_dir, "http_audit.log") : nil
    end

    SSE_INTERVAL = 1 # seconds between snapshot checks pushed to /api/events subscribers

    LOOPBACK_HOSTS = %w[127.0.0.1 ::1 localhost].freeze

    # The API can pause/kill encodes and power the machine off, so it must not be
    # reachable from the network without a token.
    def self.exposed_without_token?(host, token)
      (token.nil? || token.to_s.empty?) && !LOOPBACK_HOSTS.include?(host.to_s)
    end

    def start
      if self.class.exposed_without_token?(@host, @token)
        raise ArgumentError, "refusing to bind HTTP API to #{@host} without http_token " \
                             "(set http_token, or use http_host: 127.0.0.1)"
      end
      @server     = TCPServer.new(@host, @port)
      @thread     = Thread.new { accept_loop }
      @sse_thread = Thread.new { sse_broadcast_loop }
      @logger.info "HTTP API: http://#{@host}:#{@port}/api"
    end

    def stop
      @server&.close rescue nil
      @sse_thread&.kill
      @sse_mutex.synchronize do
        @sse_clients.each { |c| c.close rescue nil }
        @sse_clients.clear
      end
    end

    private

    def token_ok?(header)
      expected = "Bearer #{@token}"
      header.is_a?(String) && header.bytesize == expected.bytesize &&
        OpenSSL.fixed_length_secure_compare(header, expected)
    end

    def accept_loop
      loop do
        client = @server.accept
        Thread.new(client) { |c| handle(c) }
      end
    rescue IOError, Errno::EBADF
      # normal shutdown
    end

    def handle(client)
      sse = false
      ip  = client.peeraddr(false)[3] rescue "unknown"

      line = client.gets&.chomp
      return unless line

      method, raw_path, = line.split(" ", 3)
      path, query = raw_path.split("?", 2)

      headers = {}
      while (h = client.gets&.chomp) && !h.empty?
        k, v = h.split(": ", 2)
        headers[k.downcase] = v if k
      end

      body = ""
      if headers["content-length"].to_i > 0
        body = client.read(headers["content-length"].to_i)
      end

      # Handle CORS preflight
      if method == "OPTIONS"
        write_response(client, 204, nil, cors: true)
        return
      end

      if blocked?(ip)
        audit(ip, method, path, 429, "blocked")
        write_response(client, 429, { error: "Too many failed auth attempts, try again later" })
        return
      end

      # Token auth
      if @token
        auth = headers["authorization"]
        unless token_ok?(auth)
          register_failure(ip)
          audit(ip, method, path, 401, "unauthorized")
          write_response(client, 401, { error: "Unauthorized" })
          return
        end
        clear_failures(ip)
      end

      params = parse_query(query)
      params.merge!(JSON.parse(body)) unless body.empty?

      if method == "GET" && path == "/api/events"
        sse = true
        audit(ip, method, path, 200, "ok")
        handle_sse(client)
        return
      end

      result = dispatch(method, path, params)
      audit(ip, method, path, 200, "ok")
      write_response(client, 200, result)
    rescue => e
      @logger.debug "HTTP handler error: #{e.message}"
      write_response(client, 500, { error: e.message }) rescue nil
    ensure
      client.close rescue nil unless sse
    end

    def parse_query(query)
      return {} unless query && !query.empty?
      query.split("&").each_with_object({}) do |pair, h|
        k, v = pair.split("=", 2)
        next unless k
        h[URI.decode_www_form_component(k)] = URI.decode_www_form_component(v || "")
      end
    end

    # --- Server-Sent Events (/api/events) ---
    # Pushes a combined status+queue+watches snapshot to connected clients
    # every SSE_INTERVAL seconds, and immediately whenever the snapshot changes,
    # so the Plasma widget no longer has to poll three endpoints on a timer.

    def handle_sse(client)
      headers = [
        "HTTP/1.1 200 OK",
        "Content-Type: text/event-stream",
        "Cache-Control: no-cache",
        "Connection: keep-alive",
        "",
        ""
      ]
      client.write(headers.join("\r\n"))
      client.flush

      write_sse(client, api_snapshot)

      @sse_mutex.synchronize { @sse_clients << client }
    rescue => e
      @logger.debug "SSE setup error: #{e.message}"
      client.close rescue nil
    end

    def sse_broadcast_loop
      last_snapshot_json = nil
      loop do
        sleep SSE_INTERVAL
        snapshot      = api_snapshot
        snapshot_json = JSON.generate(snapshot)
        next if snapshot_json == last_snapshot_json && @sse_mutex.synchronize { @sse_clients.empty? }

        last_snapshot_json = snapshot_json
        clients = @sse_mutex.synchronize { @sse_clients.dup }
        dead    = []
        clients.each do |c|
          begin
            write_sse(c, snapshot, precomputed_json: snapshot_json)
          rescue IOError, Errno::EPIPE, Errno::ECONNRESET
            dead << c
          end
        end
        next if dead.empty?
        @sse_mutex.synchronize { @sse_clients -= dead }
        dead.each { |c| c.close rescue nil }
      end
    rescue => e
      @logger.error "SSE broadcast loop crashed: #{e.message}"
    end

    def write_sse(client, payload, precomputed_json: nil)
      json = precomputed_json || JSON.generate(payload)
      client.write("data: #{json}\n\n")
      client.flush
    end

    def api_snapshot
      { status: api_status, queue: api_queue, watches: api_watches, history: api_history_stats }
    end

    def api_history_stats
      @history ? @history.stats : nil
    end

    def dispatch(method, path, params)
      case [method, path]
      when ["GET",  "/api/status"]        then api_status
      when ["GET",  "/api/queue"]         then api_queue
      when ["GET",  "/api/watches"]       then api_watches
      when ["GET",  "/api/job-output"]    then api_job_output(params)
      when ["GET",  "/api/history"]       then api_history
      when ["POST", "/api/queue-reorder"] then api_queue_reorder(params)
      when ["POST", "/api/flush-queue"]   then api_flush_queue
      when ["POST", "/api/drain"]         then api_drain
      when ["POST", "/api/stop-job"]      then api_stop_job(params)
      when ["POST", "/api/pause"]         then api_pause(params)
      when ["POST", "/api/unpause"]       then api_unpause
      when ["POST", "/api/resume"]        then api_resume
      when ["POST", "/api/power"]         then api_power(params)
      when ["POST", "/api/watch-toggle"]  then api_watch_toggle(params)
      when ["POST", "/api/config"]        then api_config(params)
      when ["POST", "/api/retry-job"]     then api_retry_job(params)
      else { error: "not found: #{path}" }
      end
    end

    # --- handlers ---

    def api_status
      running = @mutex.synchronize do
        @pid_map.map { |path, info| { path: path }.merge(info.reject { |k, _| k == :output }.transform_keys(&:to_s)) }
      end
      running.each { |j| j[:duration] = @durations&.get(j[:path]) }
      {
        running: running,
        queued:  @queue.length,
        watches: @watcher.watched_paths.length,
        stopped:      @control.stopped?,
        paused:       @control.paused?,
        after_action: @control.after,
        power_error:  @control.power_error,
        config:  {
          workers:               @config.workers,
          idle_shutdown:         @config.idle_shutdown,
          idle_shutdown_timeout: @config.idle_shutdown_timeout,
          idle_shutdown_command: @config.idle_shutdown_command
        }
      }
    end

    def api_queue
      order = @queue.snapshot.map(&:path)
      jobs  = @mutex.synchronize do
        @pending_jobs.map { |j| { path: j.path, watch: File.basename(j.watch_path), priority: j.priority } }
      end
      jobs.each { |j| j[:duration] = @durations&.get(j[:path]) }
      jobs.sort_by! { |j| order.index(j[:path]) || order.length }
      { queued: jobs.length, jobs: jobs }
    end

    def api_watches
      { watches: @watcher.watched_configs }
    end

    def api_job_output(params)
      path = params["path"]
      return { error: "path required" } unless path
      output = @mutex.synchronize { @pid_map[path]&.fetch(:output, [])&.dup }
      return { error: "job not running: #{path}" } unless output
      { path: path, output: output }
    end

    def api_queue_reorder(params)
      paths = params["paths"]
      return { error: "paths must be an array" } unless paths.is_a?(Array)
      @queue.reorder!(paths, id_for: ->(job) { job.path })
      { ok: true }
    end

    def api_watch_toggle(params)
      path = params["path"]
      return { error: "path required" } unless path
      ok = @config.set_watch_enabled(path, !!params["enabled"])
      ok ? { ok: true } : { error: "watch not found: #{path}" }
    end

    def api_flush_queue
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
    ensure
      return { ok: true, flushed: flushed }
    end

    def api_drain
      @on_drain&.call
      { ok: true }
    end

    # Kills ffmpeg immediately (SIGKILL) and holds the queue until /api/resume.
    def api_stop_job(params)
      killed = @control.stop(path: params["path"], all: !!params["all"])
      { ok: true, killed: killed }
    end

    # Freezes ffmpeg (SIGSTOP) without losing progress and holds the queue until /api/unpause.
    def api_pause(params)
      { ok: true, paused: @control.pause(path: params["path"], all: !!params["all"]) }
    end

    def api_unpause
      { ok: true, continued: @control.unpause }
    end

    def api_resume
      @control.resume
      { ok: true }
    end

    def api_power(params)
      action = params["action"].to_s
      return { error: "action must be one of: #{Control::AFTER_ACTIONS.join(", ")}" } unless @control.set_after(action)
      { ok: true, after_action: action }
    end

    def api_config(params)
      return { error: "config updates unavailable" } unless @on_config
      # Command execution stays local-only: idle_shutdown_command can be set in config.yml
      # or over the Unix socket, never over the network.
      @on_config.call(params.reject { |k, _| k == "idle_shutdown_command" })
    end

    # Moves a previously-failed job's file from its watch's error_dir back into the
    # watch path, re-triggering inotify pickup so it's retried like a freshly-added file.
    def api_retry_job(params)
      path = params["path"]
      return { error: "path required" } unless path

      return { error: "invalid path" } if path.split("/").include?("..")

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

    # Recently completed/failed jobs with duration and size saved (compression ratio),
    # plus aggregate stats — backs the plasmoid's history/stats view and badge.
    def api_history
      return { error: "history unavailable" } unless @history
      { events: @history.to_a, stats: @history.stats }
    end

    # --- auth rate-limiting & audit log ---

    def blocked?(ip)
      until_time = @rl_mutex.synchronize { @blocked_until[ip] }
      !!(until_time && Time.now < until_time)
    end

    def register_failure(ip)
      return unless @config
      @rl_mutex.synchronize do
        now = Time.now
        attempts = (@failed_attempts[ip] << now)
        attempts.reject! { |t| now - t > @config.http_rate_limit_window }
        if attempts.length >= @config.http_rate_limit_max
          @blocked_until[ip] = now + @config.http_rate_limit_block
          @logger.warn "HTTP: blocking #{ip} for #{@config.http_rate_limit_block}s after #{attempts.length} failed auth attempts"
        end
      end
    end

    def clear_failures(ip)
      @rl_mutex.synchronize { @failed_attempts.delete(ip) }
    end

    def audit(ip, method, path, status, result)
      return unless @audit_path
      line = "[#{Time.now.strftime("%Y-%m-%dT%H:%M:%S")}] #{ip} #{method} #{path} #{status} #{result}\n"
      File.write(@audit_path, line, mode: "a")
    rescue => e
      @logger.debug "Audit log write failed: #{e.message}"
    end

    def write_response(client, status, body, cors: false)
      json    = body ? JSON.generate(body) : ""
      phrase  = { 200 => "OK", 204 => "No Content", 401 => "Unauthorized", 500 => "Internal Server Error" }.fetch(status, "OK")
      lines   = ["HTTP/1.1 #{status} #{phrase}"]
      lines  << "Content-Type: application/json" if body
      lines  << "Content-Length: #{json.bytesize}"
      lines  << "Connection: close"
      lines  << ""
      lines  << json
      client.write(lines.join("\r\n"))
    end
  end
end
