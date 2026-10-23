require "net/http"
require "json"
require "uri"
require "yaml"

module Vaks
  # Talks to a vaksd HTTP API with the same send(cmd_hash) interface as SocketClient,
  # so vaksctl can swap transports without touching the commands.
  class RemoteClient
    DEFAULT_PORT = 6283

    GET_ROUTES = {
      "status"     => "/api/status",
      "queue"      => "/api/queue",
      "watch-list" => "/api/watches",
      "history"    => "/api/history",
      "job-output" => "/api/job-output",
      "config-get" => "/api/config"
    }.freeze

    POST_ROUTES = %w[
      queue-reorder stop-job pause unpause resume power retry-job flush-queue drain
      watch-toggle watch-add watch-update watch-remove config
    ].to_h { |c| [c, "/api/#{c}"] }.freeze

    attr_reader :name, :uri

    def self.normalize_url(url)
      url = "http://#{url}" unless url.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
      uri = URI.parse(url)
      uri.port = DEFAULT_PORT if !url.match?(%r{://[^/]*:\d+}) && uri.scheme == "http"
      uri
    end

    def initialize(url:, token: nil, name: nil, timeout: 10)
      @uri     = self.class.normalize_url(url)
      @token   = token
      @name    = name || @uri.host
      @timeout = timeout
    end

    def send(cmd_hash)
      cmd  = cmd_hash["cmd"]
      args = cmd_hash.reject { |k, _| k == "cmd" }
      if (route = GET_ROUTES[cmd])
        request(Net::HTTP::Get, route, query: args)
      elsif (route = POST_ROUTES[cmd])
        request(Net::HTTP::Post, route, body: args)
      else
        raise "unsupported remote command: #{cmd.inspect}"
      end
    end

    private

    def request(klass, route, query: nil, body: nil)
      target = route
      target += "?" + URI.encode_www_form(query) if query && !query.empty?
      req = klass.new(target)
      req["Authorization"] = "Bearer #{@token}" if @token
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end

      res = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https",
                            open_timeout: @timeout, read_timeout: @timeout) { |http| http.request(req) }
      case res.code.to_i
      when 401 then raise "unauthorized by #{@name} (check the token)"
      when 429 then raise "#{@name} is rate-limiting this client after failed auth attempts; try again later"
      end
      JSON.parse(res.body)
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, Net::OpenTimeout, Net::ReadTimeout
      raise "cannot reach vaks daemon at #{@uri.scheme}://#{@uri.host}:#{@uri.port}"
    rescue JSON::ParserError
      raise "unexpected response from #{@name}"
    end
  end

  # Picks the transport: --local, then flags, env (VAKS_REMOTE / VAKS_URL / VAKS_TOKEN),
  # then ~/.config/vaks/remotes.yml, otherwise the local unix socket.
  module Remote
    DEFAULT_FILE = File.join(Config::DEFAULT_CONFIG_DIR, "remotes.yml")

    # Returns a RemoteClient, or nil for the local socket.
    def self.resolve(remote: nil, token: nil, local: false, env: ENV,
                     file: DEFAULT_FILE)
      return nil if local

      data    = load_file(file)
      remotes = data["remotes"].is_a?(Hash) ? data["remotes"] : {}
      target  = remote || env["VAKS_REMOTE"] || env["VAKS_URL"] || data["default"]
      return nil if target.nil? || target.to_s.empty?

      entry = remotes[target.to_s]
      raise "unknown remote #{target.inspect} (not in #{file})" if entry && !entry.is_a?(Hash)
      url = entry ? entry["url"] : target.to_s
      raise "remote #{target.inspect} has no url in #{file}" if url.nil? || url.to_s.empty?

      RemoteClient.new(url: url, token: token || env["VAKS_TOKEN"] || entry&.dig("token"),
                       name: entry ? target.to_s : nil)
    end

    # Every remote named in remotes.yml as [name, RemoteClient] pairs. An explicit token
    # (flag) overrides the per-remote ones.
    def self.all(token: nil, file: DEFAULT_FILE)
      remotes = load_file(file)["remotes"]
      return [] unless remotes.is_a?(Hash)
      remotes.filter_map do |name, entry|
        next unless entry.is_a?(Hash) && entry["url"]
        [name.to_s, RemoteClient.new(url: entry["url"], token: token || entry["token"], name: name.to_s)]
      end
    end

    def self.load_file(file)
      return {} unless File.exist?(file)
      if File.stat(file).mode & 0o077 != 0
        warn "vaks: #{file} is readable by other users; run `chmod 600 #{file}`"
      end
      YAML.safe_load_file(file) || {}
    rescue Psych::Exception => e
      raise "cannot read #{file}: #{e.message}"
    end
  end
end
