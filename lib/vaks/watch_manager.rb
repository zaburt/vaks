require "pathname"

module Vaks
  # Adds, edits and removes watch configs from plain string-keyed hashes, so the
  # HTTP API and the local CLI share one set of rules.
  #
  # With strict: true (HTTP API) paths must be absolute, free of "..", an existing
  # directory, and inside config.allowed_roots when that list is set.
  class WatchManager
    class Error < StandardError; end

    DIR_KEYS     = %w[done_dir working_dir source_done_dir error_dir].freeze
    INT_KEYS     = %w[delay priority retries min_free_space_mb nice ionice_class ionice_level].freeze
    STRING_KEYS  = %w[profile_preset webhook_url].freeze
    PROFILE_KEYS = %w[codec_video codec_audio codec_subtitle resolution smart_audio extra_args].freeze
    EDITABLE     = (DIR_KEYS + INT_KEYS + STRING_KEYS + %w[custom enabled webhook_events profile]).freeze

    def initialize(config, strict: true)
      @config = config
      @strict = strict
    end

    def add(params)
      path = validated_path(params["path"], must_exist: @strict)
      raise Error, "already watched: #{path}" if @config.watch_configs.any? { |w| w[:path] == path }

      fields  = clean_fields(params)
      profile = @config.default_profile.merge(symbolize(fields.delete("profile") || {}))
      file = @config.write_watch_config(
        watch_path: path, profile: profile,
        done_dir:   fields.delete("done_dir")  || "done",
        error_dir:  fields.delete("error_dir") || "error",
        delay:      fields.delete("delay")     || 0,
        priority:   fields.delete("priority")  || 0,
        custom:     fields.delete("custom")    || false,
        enabled:    fields.key?("enabled") ? fields.delete("enabled") : true,
        **fields.transform_keys(&:to_sym)
      )
      { ok: true, path: path, config_file: file }
    end

    # Fields set to nil are removed from the watch (back to the global default).
    def update(params)
      path    = validated_path(params["path"], must_exist: false)
      changes = clean_fields(params, allow_nil: true)
      raise Error, "nothing to update" if changes.empty?
      raise Error, "watch not found: #{path}" unless @config.update_watch_config(path, changes)
      { ok: true, path: path }
    end

    def remove(params)
      path = validated_path(params["path"], must_exist: false)
      raise Error, "watch not found: #{path}" unless @config.delete_watch_config(path)
      { ok: true, path: path }
    end

    private

    def validated_path(path, must_exist:)
      raise Error, "path required" unless path.is_a?(String) && !path.empty?
      path = File.expand_path(path) unless @strict
      raise Error, "path must be absolute: #{path}" unless Pathname.new(path).absolute?
      raise Error, "invalid path" if path.split("/").include?("..")
      path = path.chomp("/") unless path == "/"
      raise Error, "not a directory: #{path}" if must_exist && !File.directory?(path)
      check_root!(path)
      path
    end

    def check_root!(path)
      return unless @strict
      roots = @config.allowed_roots
      return if roots.empty?
      real = File.exist?(path) ? File.realpath(path) : path
      return if roots.any? { |r| real == r || real.start_with?(r + "/") }
      raise Error, "path is outside allowed_roots: #{path}"
    end

    def clean_fields(params, allow_nil: false)
      out = {}
      params.each do |key, value|
        next if key == "path"
        raise Error, "unknown field: #{key}" unless EDITABLE.include?(key)
        if value.nil?
          raise Error, "#{key} cannot be null" unless allow_nil || key == "profile"
          out[key] = nil unless key == "profile"
          next
        end
        out[key] = coerce(key, value)
      end
      out
    end

    def coerce(key, value)
      case key
      when *DIR_KEYS     then dir!(key, value)
      when *INT_KEYS     then Integer(value, exception: false) || raise(Error, "#{key} must be an integer")
      when *STRING_KEYS  then string!(key, value)
      when "custom", "enabled"
        raise Error, "#{key} must be true or false" unless [true, false].include?(value)
        value
      when "webhook_events"
        raise Error, "webhook_events must be a list" unless value.is_a?(Array)
        value.map(&:to_s)
      when "profile" then profile!(value)
      end
    end

    def string!(key, value)
      raise Error, "#{key} must be a string" unless value.is_a?(String)
      raise Error, "webhook_url must be an http(s) URL" if key == "webhook_url" && !value.match?(%r{\Ahttps?://})
      value
    end

    def dir!(key, value)
      raise Error, "#{key} must be a string" unless value.is_a?(String) && !value.empty?
      raise Error, "invalid #{key}" if value.split("/").include?("..")
      check_root!(value) if Pathname.new(value).absolute?
      value
    end

    # nil values are kept so an update can remove a profile key
    def profile!(value)
      raise Error, "profile must be an object" unless value.is_a?(Hash)
      value.each_with_object({}) do |(k, v), h|
        raise Error, "unknown profile field: #{k}" unless PROFILE_KEYS.include?(k)
        h[k] = v
      end
    end

    def symbolize(hash)
      hash.transform_keys(&:to_sym).compact
    end
  end
end
