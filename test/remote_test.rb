require_relative "test_helper"

class RemoteTest < Minitest::Test
  Watcher = Struct.new(:watched_paths, :watched_configs)

  def setup
    @dir = Dir.mktmpdir
    @media = File.join(@dir, "media")
    FileUtils.mkdir_p(File.join(@media, "inbox"))
    File.write(File.join(@dir, "config.yml"), { "allowed_roots" => [@media] }.to_yaml)
    @config = Vaks::Config.new(config_dir: @dir)
    @server = Vaks::HttpServer.new(
      host: "127.0.0.1", port: 0, token: "tok", queue: Vaks::PriorityQueue.new, in_flight: {},
      pending_jobs: [], pid_map: {}, mutex: Mutex.new, watcher: Watcher.new([], []),
      config: @config, logger: null_logger
    )
    @server.start
    @port = @server.instance_variable_get(:@server).addr[1]
    @client = Vaks::RemoteClient.new(url: "127.0.0.1:#{@port}", token: "tok")
  end

  def teardown
    @server.stop
    FileUtils.remove_entry(@dir)
  end

  def inbox = File.join(@media, "inbox")

  def test_watch_add_update_remove_roundtrip
    res = @client.send("cmd" => "watch-add", "path" => inbox, "priority" => 3,
                       "profile" => { "codec_video" => "libx265" })
    assert res["ok"], res.inspect
    wc = @config.watch_configs.first
    assert_equal 3, wc[:priority]
    assert_equal "libx265", wc[:profile][:codec_video]

    assert @client.send("cmd" => "watch-update", "path" => inbox, "priority" => 7,
                        "profile" => { "codec_video" => nil, "codec_audio" => "aac" })["ok"]
    wc = @config.watch_configs.first
    assert_equal 7, wc[:priority]
    assert_equal({ codec_audio: "aac" }, wc[:profile])

    assert @client.send("cmd" => "watch-remove", "path" => inbox)["ok"]
    assert_empty @config.watch_configs
  end

  def test_watch_add_rejects_unsafe_input
    other = Dir.mktmpdir
    {
      other                                => "outside allowed_roots",
      "#{inbox}/../../etc"                  => "invalid path",
      "relative/dir"                        => "must be absolute",
      File.join(@media, "missing")          => "not a directory"
    }.each do |path, msg|
      assert_includes @client.send("cmd" => "watch-add", "path" => path)["error"], msg
    end
    assert_includes @client.send("cmd" => "watch-add", "path" => inbox, "done_dir" => other)["error"], "allowed_roots"
    assert_includes @client.send("cmd" => "watch-add", "path" => inbox, "bogus" => 1)["error"], "unknown field"
    assert_includes @client.send("cmd" => "watch-add", "path" => inbox, "webhook_url" => "file:///x")["error"], "http(s)"
    assert_empty @config.watch_configs
  ensure
    FileUtils.remove_entry(other)
  end

  def test_watch_add_duplicate_and_remove_unknown
    @client.send("cmd" => "watch-add", "path" => inbox)
    assert_includes @client.send("cmd" => "watch-add", "path" => inbox)["error"], "already watched"
    assert_includes @client.send("cmd" => "watch-remove", "path" => File.join(@media, "nope"))["error"], "not found"
  end

  def test_config_endpoint_hides_secrets
    res = @client.send("cmd" => "config-get")
    assert_equal [@media], res["allowed_roots"]
    refute_includes res.keys, "http_token"
  end

  def test_wrong_token_is_reported
    bad = Vaks::RemoteClient.new(url: "127.0.0.1:#{@port}", token: "nope")
    err = assert_raises(RuntimeError) { bad.send("cmd" => "config-get") }
    assert_includes err.message, "unauthorized"
  end

  def test_unreachable_daemon
    err = assert_raises(RuntimeError) { Vaks::RemoteClient.new(url: "127.0.0.1:1").send("cmd" => "config-get") }
    assert_includes err.message, "cannot reach"
  end

  def test_normalize_url_defaults_port
    assert_equal 6283, Vaks::RemoteClient.normalize_url("desk").port
    assert_equal 9000, Vaks::RemoteClient.normalize_url("http://desk:9000").port
  end

  def test_resolve_precedence
    file = File.join(@dir, "remotes.yml")
    File.write(file, { "default" => "desk",
                       "remotes" => { "desk" => { "url" => "http://desk:1", "token" => "file" },
                                      "nas"  => { "url" => "http://nas:2" } } }.to_yaml)
    File.chmod(0o600, file)

    desk = Vaks::Remote.resolve(env: {}, file: file)
    assert_equal ["desk", 1], [desk.uri.host, desk.uri.port]
    assert_equal "file", desk.instance_variable_get(:@token)

    env = Vaks::Remote.resolve(env: { "VAKS_REMOTE" => "nas", "VAKS_TOKEN" => "env" }, file: file)
    assert_equal ["nas", "env"], [env.uri.host, env.instance_variable_get(:@token)]

    flag = Vaks::Remote.resolve(remote: "10.0.0.5", token: "flag", env: { "VAKS_REMOTE" => "nas" }, file: file)
    assert_equal ["10.0.0.5", 6283, "flag"], [flag.uri.host, flag.uri.port, flag.instance_variable_get(:@token)]

    assert_nil Vaks::Remote.resolve(local: true, env: {}, file: file)
    assert_nil Vaks::Remote.resolve(env: {}, file: File.join(@dir, "missing.yml"))
  end

  def test_all_lists_every_remote_with_flag_token_override
    file = File.join(@dir, "remotes.yml")
    File.write(file, { "remotes" => { "desk" => { "url" => "desk", "token" => "a" },
                                      "nas" => { "url" => "nas:9", "token" => "b" },
                                      "bad" => "oops" } }.to_yaml)
    File.chmod(0o600, file)

    all = Vaks::Remote.all(file: file)
    assert_equal %w[desk nas], all.map(&:first)
    assert_equal %w[a b], all.map { |_, c| c.instance_variable_get(:@token) }
    assert_equal ["x", "x"], Vaks::Remote.all(token: "x", file: file).map { |_, c| c.instance_variable_get(:@token) }
    assert_empty Vaks::Remote.all(file: File.join(@dir, "missing.yml"))
  end
end
