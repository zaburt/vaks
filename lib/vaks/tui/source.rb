require "json"

module Vaks
  module TUI
    # One daemon the TUI can talk to: a remote HTTP API or the local unix socket.
    class Source
      attr_reader :name, :client

      def initialize(name:, client:, remote:)
        @name   = name
        @client = client
        @remote = remote
      end

      def remote? = @remote

      def send(cmd, **args) = @client.send({ "cmd" => cmd }.merge(args.transform_keys(&:to_s)))

      # Remote: the daemon validates and writes the watch. Local: write the config directly,
      # like `vaksctl watch`.
      def manage_watch(action, params)
        return send("watch-#{action}", **params.transform_keys(&:to_sym)) if remote?
        res = WatchManager.new(Config.new, strict: false).public_send(action, params)
        JSON.parse(JSON.generate(res))
      rescue WatchManager::Error => e
        { "error" => e.message }
      end

      # The local socket, then every remote in remotes.yml, with the active one first.
      def self.discover(active_client:, active_name:, active_remote:, token: nil)
        sources = [new(name: active_name, client: active_client, remote: active_remote)]
        Remote.all(token: token).each do |name, client|
          next if active_remote && client.uri == active_client.uri
          sources << new(name: name, client: client, remote: true)
        end
        unless sources.any? { |s| !s.remote? }
          sources << new(name: "local", client: SocketClient.new(Config.new.socket_path), remote: false)
        end
        sources
      end
    end

    # Builds watch-add/watch-update payloads from form changes.
    module WatchParams
      PROFILE_KEYS = WatchManager::PROFILE_KEYS
      INT_KEYS     = WatchManager::INT_KEYS

      module_function

      # `changes` maps field => string, or nil to clear the field. Raises ArgumentError on a
      # non-numeric integer field.
      def build(path, changes, keep_nil:)
        params  = { "path" => path }
        profile = {}
        changes.each do |key, value|
          next if value.nil? && !keep_nil
          if PROFILE_KEYS.include?(key)
            profile[key] = value
          elsif INT_KEYS.include?(key)
            params[key] = value.nil? ? nil : Integer(value, exception: false) || raise(ArgumentError, "#{key} must be a number")
          else
            params[key] = value
          end
        end
        params["profile"] = profile unless profile.empty?
        params
      end
    end

    # Fetches daemon state on a background thread, about once a second. The UI only reads
    # snapshots, so a slow or unreachable daemon never blocks drawing.
    class Poller
      INTERVAL      = 1.0
      HISTORY_EVERY = 3

      def initialize(source)
        @mutex       = Mutex.new
        @wake        = Queue.new
        @gen         = 0
        @tick        = 0
        @output_path = nil
        use(source)
      end

      def use(source)
        @mutex.synchronize do
          @source = source
          @gen += 1
          @snap = { source: source.name, error: nil, loaded: false }
        end
        refresh
      end

      def watch_output(path)
        @mutex.synchronize { @output_path = path }
        refresh
      end

      def snapshot = @mutex.synchronize { @snap }

      def refresh = @wake << true

      def start
        @thread = Thread.new do
          loop do
            poll
            @wake.pop(timeout: INTERVAL)
            @wake.clear
          end
        end
      end

      def stop = @thread&.kill

      private

      def poll
        source, gen, path, have_history = @mutex.synchronize { [@source, @gen, @output_path, !@snap[:history].nil?] }
        data = { source: source.name, error: nil, loaded: true }
        begin
          data[:status]  = source.send("status")
          data[:queue]   = source.send("queue")
          data[:watches] = source.send("watch-list")
          data[:history] = source.send("history") if (@tick % HISTORY_EVERY).zero? || !have_history
          data[:output]  = source.send("job-output", path: path) if path
        rescue => e
          data[:error] = e.message
        end
        @tick += 1
        @mutex.synchronize do
          next unless gen == @gen
          # Keep the last good data on a failed poll so the screen doesn't blank out.
          merged = (@snap || {}).merge(data.reject { |_, v| v.nil? })
          merged[:error] = data[:error]
          merged[:output] = nil if path.nil?
          @snap = merged
        end
      end
    end
  end
end
