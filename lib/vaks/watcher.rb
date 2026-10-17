require "rb-inotify"
require "fileutils"
require "set"
require "yaml"

module Vaks
  class Watcher
    SIDECAR_SUFFIX = ".vaks.yml"

    def initialize(config:, queue:, in_flight:, pending_jobs:, mutex:, logger:, extensions:)
      @config       = config
      @queue        = queue
      @in_flight    = in_flight
      @pending_jobs = pending_jobs
      @mutex        = mutex
      @logger       = logger
      @extensions   = extensions

      @notifier       = INotify::Notifier.new
      @active_watches = {}  # watch_path => INotify::Watch
      @watch_configs  = {}  # watch_path => config hash
    end

    def start
      FileUtils.mkdir_p(@config.watches_dir)

      @notifier.watch(@config.watches_dir, :close_write, :moved_to, :delete, :moved_from) do |event|
        handle_config_event(event)
      end

      @config.watch_configs.each do |wc|
        clean_working_dir(wc)
        register_watch(wc)
      end

      @thread = Thread.new do
        @notifier.run
      rescue => e
        @logger.error "Watcher thread error: #{e.message}"
      end

      @logger.info "Config dir: #{@config.watches_dir}"
    end

    def stop
      @notifier.close rescue nil
      @thread&.join(5)
    end

    def watched_paths
      @watch_configs.keys
    end

    # Returns serializable watch config details for the watch list command.
    def watched_configs
      @watch_configs.values.map do |wc|
        {
          "path"            => wc[:path],
          "done_dir"        => wc[:done_dir],
          "working_dir"     => wc[:working_dir],
          "source_done_dir" => wc[:source_done_dir],
          "error_dir"       => wc[:error_dir],
          "delay"           => wc[:delay],
          "priority"        => wc[:priority],
          "custom"          => wc[:custom],
          "enabled"         => wc.fetch(:enabled, true),
          "profile"         => wc[:profile].transform_keys(&:to_s),
          "profile_preset"  => wc[:profile_preset],
          "retries"         => wc[:retries],
          "min_free_space_mb" => wc[:min_free_space_mb],
          "webhook_url"     => wc[:webhook_url],
          "nice"            => wc[:nice],
          "ionice_class"    => wc[:ionice_class],
          "ionice_level"    => wc[:ionice_level]
        }.compact
      end
    end

    private

    # Removes any files left over in a watch's working_dir from a previous run that
    # was interrupted (crash, kill -9, power loss) before it could finish moving the
    # encoded file to done/. Only run once, at daemon startup — never during a
    # hot-reload — so an in-progress job's temp output is never touched.
    def clean_working_dir(wc)
      dir = wc[:working_dir]
      return unless dir && Dir.exist?(dir)

      Dir.children(dir).each do |name|
        full = File.join(dir, name)
        next unless File.file?(full)
        FileUtils.rm_f(full)
        @logger.info "Removed stale working file from a previous run: #{full}"
      end
    rescue => e
      @logger.warn "Could not clean working dir #{dir}: #{e.message}"
    end

    def handle_config_event(event)
      return unless event.name.end_with?(".yml")

      if event.flags.any? { |f| %i[delete moved_from].include?(f) }
        wc = @watch_configs.values.find { |w| w[:config_file] == event.absolute_name }
        @logger.info "Watch config removed: #{event.name} (#{wc ? wc[:path] : 'unknown path'})"
        unregister_watch(wc[:path]) if wc
      else
        wc = @config.load_watch_config(event.absolute_name)
        return unless wc

        @logger.info "Watch config event (#{event.flags.join(', ')}): #{event.name} → #{wc[:path]}"
        unregister_watch(wc[:path]) if @watch_configs[wc[:path]]
        register_watch(wc)
      end
    end

    def register_watch(wc)
      watch_path = wc[:path]

      unless Dir.exist?(watch_path)
        @logger.warn "Watch path does not exist, skipping: #{watch_path}"
        return
      end

      @watch_configs[watch_path] = wc

      descriptor = @notifier.watch(watch_path, :close_write, :moved_to, :moved_from, :delete) do |event|
        next if event.flags.include?(:isdir)
        path = event.absolute_name
        if event.flags.any? { |f| %i[moved_from delete].include?(f) }
          dequeue_removed(path)
          next
        end
        if wc[:custom]
          if path.end_with?(SIDECAR_SUFFIX)
            enqueue_from_sidecar(path, wc)
          else
            enqueue_custom(path, wc)
          end
        else
          enqueue(path, wc)
        end
      end
      @active_watches[watch_path] = descriptor

      @logger.info "Watching: #{watch_path}#{" (custom)" if wc[:custom]}#{" (suspended)" unless wc.fetch(:enabled, true)}"

      scan(watch_path, wc) if wc.fetch(:enabled, true)
    end

    def unregister_watch(watch_path)
      @active_watches.delete(watch_path)&.close rescue nil
      @watch_configs.delete(watch_path)
      @logger.info "Stopped watching: #{watch_path}"
    end

    def scan(path, wc)
      Dir.children(path).sort.each do |name|
        full = File.join(path, name)
        next unless File.file?(full)
        if wc[:custom]
          if full.end_with?(SIDECAR_SUFFIX)
            enqueue_from_sidecar(full, wc)
          else
            enqueue_custom(full, wc)
          end
        else
          enqueue(full, wc)
        end
      end
    end

    # Standard (non-custom) enqueue
    def enqueue(path, wc)
      ext = File.extname(path).delete_prefix(".").downcase
      return unless @extensions.include?(ext)
      enqueue_job(path, wc[:profile], wc)
    end

    # Custom watch: media file arrived — only enqueue if sidecar exists
    def enqueue_custom(path, wc)
      ext = File.extname(path).delete_prefix(".").downcase
      return unless @extensions.include?(ext)
      sidecar = path + SIDECAR_SUFFIX
      return unless File.file?(sidecar)
      profile = wc[:profile].merge(load_sidecar_profile(sidecar))
      enqueue_job(path, profile, wc)
    end

    # Custom watch: sidecar arrived — find media file and enqueue if present
    def enqueue_from_sidecar(sidecar_path, wc)
      media_path = sidecar_path.delete_suffix(SIDECAR_SUFFIX)
      return unless File.file?(media_path)
      ext = File.extname(media_path).delete_prefix(".").downcase
      return unless @extensions.include?(ext)
      profile = wc[:profile].merge(load_sidecar_profile(sidecar_path))
      enqueue_job(media_path, profile, wc)
    end

    def enqueue_job(path, profile, wc)
      return unless wc.fetch(:enabled, true)

      @mutex.synchronize do
        return if @in_flight.include?(path)
        @in_flight.add(path)
      end

      job = Job.new(
        path:              path,
        profile:           profile.dup,
        done_dir:          wc[:done_dir],
        working_dir:       wc[:working_dir],
        source_done_dir:   wc[:source_done_dir],
        error_dir:         wc[:error_dir],
        watch_path:        wc[:path],
        delay:             wc.fetch(:delay, 0),
        priority:          effective_priority(path, wc),
        retries:           wc.fetch(:retries, 0),
        min_free_space_mb: wc[:min_free_space_mb],
        webhook_url:       wc[:webhook_url],
        webhook_events:    wc.fetch(:webhook_events, %w[success failure]),
        nice:              wc[:nice],
        ionice_class:      wc[:ionice_class],
        ionice_level:      wc[:ionice_level]
      )

      @mutex.synchronize { @pending_jobs << job }
      @queue << job
      @logger.info "Queued: #{File.basename(path)} (#{File.basename(wc[:path])})"
    end

    # A file was moved out of (or deleted from) a watched directory before a worker
    # picked it up — drop its still-pending job so it doesn't linger in the queue
    # (and, when moved into another watched directory, doesn't get processed twice).
    # Jobs already being encoded are left alone; the worker's own "no longer exists"
    # check covers the rare race where removal happens right as a worker pops it.
    def dequeue_removed(path)
      removed = @mutex.synchronize do
        if (job = @pending_jobs.find { |j| j.path == path })
          @pending_jobs.delete(job)
          true
        else
          false
        end
      end
      return unless removed

      @queue.delete_if { |item| item.respond_to?(:path) && item.path == path }
      @mutex.synchronize { @in_flight.delete(path) }
      @logger.info "Removed from queue (moved/deleted before processing): #{File.basename(path)}"
    end

    # Boosts a job's priority when the source file is small, so quick jobs don't
    # wait behind long-running ones already ahead of them in the queue.
    def effective_priority(path, wc)
      base  = wc.fetch(:priority, 0)
      limit = @config.small_file_bytes
      return base unless limit

      size = File.size(path)
      size <= limit ? base + @config.small_file_priority_boost : base
    rescue Errno::ENOENT
      base
    end

    def load_sidecar_profile(sidecar_path)
      raw = YAML.safe_load_file(sidecar_path) || {}
      raw.transform_keys(&:to_sym)
    rescue => e
      @logger.warn "Could not read sidecar #{sidecar_path}: #{e.message}"
      {}
    end
  end
end
