require "logger"
require "fileutils"
require "set"
require "securerandom"

module Vaks
  class Vaksd
    def initialize(config: nil)
      @config       = config || Config.new
      @logger       = build_logger
      @queue        = PriorityQueue.new
      @in_flight    = Set.new
      @pending_jobs = []
      @pid_map      = {}
      @mutex        = Mutex.new
      @draining     = false
      @workers      = []
      @history      = History.new
      @durations    = Durations.new
      @control      = Control.new(queue: @queue, in_flight: @in_flight, pid_map: @pid_map,
                                  mutex: @mutex, logger: @logger)
    end

    def run
      FileUtils.mkdir_p(@config.config_dir)
      FileUtils.mkdir_p(@config.watches_dir)

      abort_unless_ffmpeg_present

      @logger.info "vaks #{VERSION} starting (workers: #{@config.workers})"

      setup_signal_handlers
      start_workers_with_optional_delay

      @watcher = Watcher.new(
        config:       @config,
        queue:        @queue,
        in_flight:    @in_flight,
        pending_jobs: @pending_jobs,
        mutex:        @mutex,
        logger:       @logger,
        extensions:   @config.extensions
      )
      @watcher.start

      @socket_server = SocketServer.new(
        socket_path:  @config.socket_path,
        queue:        @queue,
        in_flight:    @in_flight,
        pending_jobs: @pending_jobs,
        pid_map:      @pid_map,
        mutex:        @mutex,
        watcher:      @watcher,
        logger:       @logger,
        config:       @config,
        history:      @history,
        control:      @control,
        on_drain:     method(:drain),
        on_config:    method(:apply_config)
      )
      @socket_server.start

      start_http_server
      start_idle_monitor
      @control.start_monitor

      @logger.info "vaks ready"
      sleep
    end

    private

    def start_workers_with_optional_delay
      if @config.startup_delay > 0
        @logger.info "Startup delay enabled — waiting #{@config.startup_delay}s before starting workers"
        Thread.new do
          sleep @config.startup_delay
          start_workers unless @draining
        end
      else
        start_workers
      end
    end

    def apply_config(params)
      updated = []

      if params.key?("workers")
        new_count = params["workers"].to_i
        old_count = @config.workers
        if new_count > old_count
          (new_count - old_count).times do
            thread = Worker.new(
              queue:        @queue,
              in_flight:    @in_flight,
              pending_jobs: @pending_jobs,
              pid_map:      @pid_map,
              mutex:        @mutex,
              logger:       @logger,
              extensions:   @config.extensions,
              control:      @control,
              history:      @history,
              retry_delay:  @config.retry_delay
            ).start
            @workers << thread
          end
        elsif new_count < old_count
          (old_count - new_count).times { @queue << :stop }
        end
        @config.workers = new_count
        updated << "workers"
      end

      if params.key?("idle_shutdown")
        @config.idle_shutdown = params["idle_shutdown"]
        updated << "idle_shutdown"
      end

      if params.key?("idle_shutdown_timeout")
        @config.idle_shutdown_timeout = params["idle_shutdown_timeout"].to_i
        updated << "idle_shutdown_timeout"
      end

      if params.key?("idle_shutdown_command")
        @config.idle_shutdown_command = params["idle_shutdown_command"]
        updated << "idle_shutdown_command"
      end

      @logger.info "Config updated: #{updated.join(", ")}" unless updated.empty?
      { ok: true, updated: updated }
    end

    # Always runs — idle_shutdown/idle_shutdown_timeout are re-read from @config on
    # every tick so the daemon reacts to the setting being toggled at runtime (e.g.
    # via the Plasma widget's switch), not just its value at daemon startup.
    def start_idle_monitor
      Thread.new do
        idle_since     = nil
        seen_activity  = false
        was_enabled    = false

        loop do
          sleep 5
          next if @draining

          unless @config.idle_shutdown
            idle_since    = nil
            seen_activity = false
            was_enabled   = false
            next
          end

          @logger.info "Idle shutdown armed (timeout: #{@config.idle_shutdown_timeout}s)" unless was_enabled
          was_enabled = true

          if @queue.empty? && @in_flight.empty?
            # Only start counting once we've actually seen the queue/workers go busy
            # at least once while armed — so enabling this while nothing is encoding
            # doesn't shut down immediately; it only fires after some encoding has
            # happened and then finished.
            unless seen_activity
              @logger.debug "Idle shutdown armed but no encoding has run yet — waiting."
              next
            end

            idle_since ||= Time.now
            elapsed = Time.now - idle_since

            if elapsed >= @config.idle_shutdown_timeout
              @logger.info "Idle for #{@config.idle_shutdown_timeout}s — shutting down."
              drain(idle_shutdown: true)
              break
            else
              @logger.debug "Idle #{elapsed.to_i}s / #{@config.idle_shutdown_timeout}s before shutdown"
            end
          else
            seen_activity = true
            idle_since    = nil
          end
        end
      end
    end

    def start_http_server
      return unless @config.http_port

      @http_server = HttpServer.new(
        host:         @config.http_host,
        port:         @config.http_port,
        token:        @config.http_token,
        queue:        @queue,
        in_flight:    @in_flight,
        pending_jobs: @pending_jobs,
        pid_map:      @pid_map,
        mutex:        @mutex,
        watcher:      @watcher,
        config:       @config,
        history:      @history,
        control:      @control,
        durations:    @durations,
        logger:       @logger,
        on_drain:     method(:drain),
        on_config:    method(:apply_config)
      )
      @http_server.start
    rescue ArgumentError => e
      @logger.error "HTTP API disabled: #{e.message}"
      @http_server = nil
    end

    def start_workers
      @config.workers.times do
        thread = Worker.new(
          queue:        @queue,
          in_flight:    @in_flight,
          pending_jobs: @pending_jobs,
          pid_map:      @pid_map,
          mutex:        @mutex,
          logger:       @logger,
          extensions:   @config.extensions,
          control:      @control,
          history:      @history,
          retry_delay:  @config.retry_delay
        ).start
        @workers << thread
      end
    end

    def setup_signal_handlers
      trap("TERM") { Thread.new { drain } }
      trap("INT")  { Thread.new { drain } }
    end

    def drain(idle_shutdown: false)
      return if @draining
      @draining = true

      @logger.info "vaks draining — waiting for current jobs to finish..."
      @control.close
      @watcher&.stop
      @socket_server&.stop
      @http_server&.stop

      @config.workers.times { @queue << :stop }
      @workers.each { |t| t.join }

      @logger.info "vaks stopped."
      run_idle_shutdown_command if idle_shutdown
      exit 0
    end

    # Runs the user-configured shutdown command (e.g. "systemctl poweroff") after
    # the daemon has fully drained. Only invoked from idle-shutdown, never from a
    # plain TERM/INT — those just stop the daemon, not the machine.
    def run_idle_shutdown_command
      command = @config.idle_shutdown_command
      return if command.nil? || command.to_s.strip.empty?

      @logger.info "Running idle_shutdown_command: #{command}"
      begin
        system(command)
      rescue => e
        @logger.error "idle_shutdown_command failed: #{e.message}"
      end
    end

    def abort_unless_ffmpeg_present
      unless Ffmpeg.version
        @logger.fatal "ffmpeg not found on PATH — cannot start"
        exit 1
      end
    end

    def build_logger
      logger           = Logger.new(log_device)
      logger.level     = Logger.const_get(@config.log_level)
      logger.formatter = proc do |severity, time, _, msg|
        "[#{time.strftime("%Y-%m-%dT%H:%M:%S")}] #{severity.ljust(5)}: #{msg}\n"
      end
      logger
    end

    def log_device
      return $stdout unless @config.log_dir

      FileUtils.mkdir_p(@config.log_dir)
      log_file      = File.open(File.join(@config.log_dir, "vaks.log"), "a")
      log_file.sync = true
      MultiIO.new($stdout, log_file)
    end

    # Broadcasts Logger output to multiple IO targets.
    class MultiIO
      def initialize(*targets)
        @targets = targets
        @mutex   = Mutex.new
      end

      def write(*args)
        @mutex.synchronize { @targets.each { |t| t.write(*args) } }
      end

      def flush
        @targets.each { |t| t.flush rescue nil }
      end

      def close
        @targets.each { |t| t.close rescue nil }
      end
    end
  end
end
