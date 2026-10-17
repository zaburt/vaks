require_relative "test_helper"
require "net/http"

class HttpServerTest < Minitest::Test
  Watcher = Struct.new(:watched_paths, :watched_configs)

  def setup
    @config_calls = []
    @server = build(token: "s3cret")
    @server.start
    @port = @server.instance_variable_get(:@server).addr[1]
  end

  def teardown
    @server.stop
  end

  def build(token:, host: "127.0.0.1")
    Vaks::HttpServer.new(
      host: host, port: 0, token: token, queue: Vaks::PriorityQueue.new, in_flight: {},
      pending_jobs: [], pid_map: {}, mutex: Mutex.new, watcher: Watcher.new([], []),
      config: nil, logger: null_logger,
      on_config: ->(params) { @config_calls << params; { ok: true } }
    )
  end

  def request(method, path, token: "s3cret", body: nil)
    req = Net::HTTP.const_get(method.capitalize).new(path)
    req["Authorization"] = "Bearer #{token}" if token
    req.body = JSON.generate(body) if body
    Net::HTTP.start("127.0.0.1", @port) { |h| h.request(req) }
  end

  def test_rejects_missing_and_wrong_token
    assert_equal "401", request(:get, "/api/nope", token: nil).code
    assert_equal "401", request(:get, "/api/nope", token: "wrong").code
    assert_equal "200", request(:get, "/api/nope").code
  end

  def test_no_wildcard_cors_header
    assert_nil request(:get, "/api/nope")["Access-Control-Allow-Origin"]
  end

  def test_config_endpoint_cannot_set_idle_shutdown_command
    request(:post, "/api/config", body: { "workers" => 3, "idle_shutdown_command" => "touch /tmp/pwned" })
    assert_equal [{ "workers" => 3 }], @config_calls
  end

  def test_retry_job_rejects_parent_directory_traversal
    res = request(:post, "/api/retry-job", body: { "path" => "/watch/../etc/x.mkv" })
    assert_equal "invalid path", JSON.parse(res.body)["error"]
  end

  def test_refuses_to_bind_off_loopback_without_token
    assert Vaks::HttpServer.exposed_without_token?("0.0.0.0", nil)
    assert Vaks::HttpServer.exposed_without_token?("0.0.0.0", "")
    refute Vaks::HttpServer.exposed_without_token?("0.0.0.0", "t")
    refute Vaks::HttpServer.exposed_without_token?("127.0.0.1", nil)
    assert_raises(ArgumentError) { build(token: nil, host: "0.0.0.0").start }
  end
end
