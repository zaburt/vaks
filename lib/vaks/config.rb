require "yaml"
require "fileutils"

module Vaks
  class Config
    DEFAULT_CONFIG_DIR = File.join(Dir.home, ".config", "vaks").freeze
    DEFAULT_EXTENSIONS = %w[mkv mp4 avi mov ts m4v webm flv wmv].freeze

    attr_reader   :config_dir, :watches_dir, :socket_path, :log_level, :extensions,
                  :default_profile, :log_dir,
                  :http_port, :http_host, :http_token, :startup_delay,
                  :default_done_dir, :default_working_dir, :default_source_done_dir, :default_error_dir,
                  :default_retries, :retry_delay, :min_free_space_mb,
                  :webhook_url, :webhook_events, :profile_presets,
                  :small_file_bytes, :small_file_priority_boost,
                  :http_rate_limit_max, :http_rate_limit_window, :http_rate_limit_block
    attr_accessor :workers, :idle_shutdown, :idle_shutdown_timeout, :idle_shutdown_command

    def initialize(config_dir: DEFAULT_CONFIG_DIR)
      @config_dir  = config_dir
      @watches_dir = File.join(config_dir, "watches")
      @socket_path = File.join(config_dir, "control.sock")

      raw = load_yaml(File.join(config_dir, "config.yml"))
      @workers                = raw.fetch("workers", 2).to_i
      @log_level              = raw.fetch("log_level", "info").upcase
      @extensions             = raw.fetch("extensions", DEFAULT_EXTENSIONS).map { |e| e.to_s.downcase.delete_prefix(".") }
      @idle_shutdown          = raw.fetch("idle_shutdown", false)
      @idle_shutdown_timeout  = raw.fetch("idle_shutdown_timeout", 30).to_i
      # Shell command run after the daemon drains, when idle_shutdown fires.
      # nil/blank means "just stop the daemon" (previous behavior). Set this to
      # something like "systemctl poweroff" or "sudo shutdown -h now" to actually
      # power off the machine once encoding finishes and it's been idle.
      @idle_shutdown_command  = raw.fetch("idle_shutdown_command", nil)
      @startup_delay          = raw.fetch("startup_delay", 0).to_i
      @default_profile        = symbolize(raw.fetch("default_profile", {}))
      @log_dir                = raw.fetch("log_dir", nil)
      @http_port              = raw.fetch("http_port", nil)&.to_i
      @http_host              = raw.fetch("http_host", "127.0.0.1")
      @http_token             = raw.fetch("http_token", nil)
      @default_done_dir        = raw.fetch("done_dir", nil)
      @default_working_dir     = raw.fetch("working_dir", nil)
      @default_source_done_dir = raw.fetch("source_done_dir", nil)
      @default_error_dir       = raw.fetch("error_dir", nil)

      # Retry policy: how many times a failed job is retried before being moved to error/
      @default_retries        = raw.fetch("retries", 0).to_i
      @retry_delay            = raw.fetch("retry_delay", 5).to_i

      # Disk-space guard: pause a job (re-queue and wait) if the target dir is low on space
      @min_free_space_mb      = raw.fetch("min_free_space_mb", nil)&.to_i

      # Webhook/notification hook fired on job success/failure (Slack/ntfy/generic JSON POST)
      @webhook_url            = raw.fetch("webhook_url", nil)
      @webhook_events         = Array(raw.fetch("webhook_events", %w[success failure])).map(&:to_s)

      # Named, reusable encoding profile presets selectable from a watch config by name
      @profile_presets        = (raw.fetch("profiles", {}) || {}).transform_values { |p| symbolize(p || {}) }

      # Small-file priority boost so quick jobs don't wait behind long ones already queued
      @small_file_bytes           = raw.fetch("small_file_bytes", nil)&.to_i
      @small_file_priority_boost  = raw.fetch("small_file_priority_boost", 5).to_i

      # HTTP API auth rate-limiting
      @http_rate_limit_max     = raw.fetch("http_rate_limit_max", 5).to_i
      @http_rate_limit_window  = raw.fetch("http_rate_limit_window", 60).to_i
      @http_rate_limit_block   = raw.fetch("http_rate_limit_block", 60).to_i
    end

    # Resolve a named profile preset (from the top-level `profiles:` map) merged with
    # any per-watch overrides. Falls back to just the overrides if the name is unknown.
    def resolve_profile(preset_name, overrides)
      base = preset_name ? (@profile_presets[preset_name.to_s] || {}) : {}
      base.merge(overrides)
    end

    # Load all watch configs from watches/*.yml
    def watch_configs
      Dir.glob(File.join(@watches_dir, "*.yml")).filter_map { |f| load_watch_config(f) }
    end

    # Load a single watch config file. Returns nil on failure or missing path key.
    def load_watch_config(file)
      raw = load_yaml(file)
      return nil unless raw.is_a?(Hash) && raw["path"]

      watch_path = raw["path"]
      {
        path:            watch_path,
        done_dir:        resolve_dir(raw["done_dir"]        || @default_done_dir        || "done",  watch_path),
        working_dir:     resolve_dir_opt(raw["working_dir"] || @default_working_dir,               watch_path),
        source_done_dir: resolve_dir_opt(raw["source_done_dir"] || @default_source_done_dir,       watch_path),
        error_dir:       resolve_dir(raw["error_dir"]       || @default_error_dir       || "error", watch_path),
        delay:           raw.fetch("delay", 0).to_i,
        priority:        raw.fetch("priority", 0).to_i,
        custom:          raw.fetch("custom", false),
        enabled:         raw.fetch("enabled", true),
        profile_preset:  raw["profile_preset"],
        profile:         resolve_profile(raw["profile_preset"], symbolize(raw.fetch("profile", {}))),
        retries:         raw.fetch("retries", @default_retries).to_i,
        min_free_space_mb: raw.fetch("min_free_space_mb", @min_free_space_mb)&.to_i,
        webhook_url:     raw.fetch("webhook_url", @webhook_url),
        webhook_events:  Array(raw.fetch("webhook_events", @webhook_events)).map(&:to_s),
        nice:            raw.fetch("nice", nil)&.to_i,
        ionice_class:    raw.fetch("ionice_class", nil)&.to_i,
        ionice_level:    raw.fetch("ionice_level", nil)&.to_i,
        config_file:     file
      }
    rescue => e
      warn "vaks: failed to load watch config #{file}: #{e.message}"
      nil
    end

    # Write a new watch config yml file. Returns the path of the written file.
    def write_watch_config(watch_path:, profile: {}, done_dir: "done", working_dir: nil,
                           source_done_dir: nil, error_dir: "error", delay: 0, priority: 0,
                           custom: false, enabled: true, profile_preset: nil, retries: nil,
                           min_free_space_mb: nil, webhook_url: nil, webhook_events: nil,
                           nice: nil, ionice_class: nil, ionice_level: nil)
      FileUtils.mkdir_p(@watches_dir)
      name = watch_path.sub(%r{\A/}, "").gsub("/", "_") + ".yml"
      file = File.join(@watches_dir, name)
      data = {
        "path"      => watch_path,
        "done_dir"  => done_dir,
        "error_dir" => error_dir,
        "delay"     => delay,
        "priority"  => priority,
        "custom"    => custom,
        "enabled"   => enabled,
        "profile"   => stringify(profile)
      }
      data["working_dir"]      = working_dir     if working_dir
      data["source_done_dir"]  = source_done_dir if source_done_dir
      data["profile_preset"]   = profile_preset  if profile_preset
      data["retries"]          = retries         if retries
      data["min_free_space_mb"] = min_free_space_mb if min_free_space_mb
      data["webhook_url"]      = webhook_url     if webhook_url
      data["webhook_events"]   = webhook_events  if webhook_events
      data["nice"]             = nice            if nice
      data["ionice_class"]     = ionice_class    if ionice_class
      data["ionice_level"]     = ionice_level    if ionice_level
      File.write(file, data.to_yaml)
      file
    end

    # Remove the watch config yml for a given watch path. Returns true if found and deleted.
    def delete_watch_config(watch_path)
      watch_configs.each do |wc|
        if wc[:path] == watch_path
          File.delete(wc[:config_file])
          return true
        end
      end
      false
    end

    # Enable or disable a watch (suspend/resume) by rewriting its yml config file.
    # Preserves the file's existing content; only the "enabled" key changes. Rewriting
    # the file triggers the daemon's existing inotify hot-reload of watches/*.yml.
    # Returns true if the watch config was found and updated.
    def set_watch_enabled(watch_path, enabled)
      watch_configs.each do |wc|
        next unless wc[:path] == watch_path
        raw = load_yaml(wc[:config_file])
        raw["enabled"] = enabled
        File.write(wc[:config_file], raw.to_yaml)
        return true
      end
      false
    end

    private

    def load_yaml(path)
      return {} unless File.exist?(path)
      YAML.safe_load_file(path) || {}
    rescue => e
      warn "vaks: failed to read #{path}: #{e.message}"
      {}
    end

    def resolve_dir(dir, watch_path)
      Pathname.new(dir).absolute? ? dir : File.join(watch_path, dir)
    end

    def resolve_dir_opt(dir, watch_path)
      return nil if dir.nil?
      Pathname.new(dir).absolute? ? dir : File.join(watch_path, dir)
    end

    def symbolize(hash)
      hash.transform_keys(&:to_sym)
    end

    def stringify(hash)
      hash.transform_keys(&:to_s)
    end
  end
end
