require_relative "test_helper"

class ControlTest < Minitest::Test
  class FakePower
    attr_reader :calls
    def initialize = @calls = []
    def call(kind) = @calls << kind
  end

  def setup
    @queue  = Vaks::PriorityQueue.new
    @pids   = {}
    @mutex  = Mutex.new
    @power  = FakePower.new
    @control = Vaks::Control.new(queue: @queue, in_flight: {}, pid_map: @pids, mutex: @mutex,
                                 logger: null_logger, power: @power)
  end

  def teardown
    @pids.each_value { |i| Process.kill("KILL", i[:pid]) rescue nil }
    Process.waitall
  end

  def spawn_sleeper(path)
    pid = Process.spawn("sleep", "30")
    @pids[path] = { pid: pid }
    pid
  end

  def test_stop_kills_process_holds_queue_and_resume_releases
    pid = spawn_sleeper("/a.mkv")
    assert_equal 1, @control.stop(all: true)
    Process.wait(pid)
    assert @control.stopped?
    assert @control.consume_kill("/a.mkv")
    refute @control.consume_kill("/a.mkv")
    @control.resume
    refute @control.stopped?
  end

  def test_pause_freezes_and_unpause_continues_same_process
    pid = spawn_sleeper("/a.mkv")
    assert_equal 1, @control.pause(path: "/a.mkv")
    assert @control.paused?
    assert @pids["/a.mkv"][:paused]
    @control.unpause
    refute @control.paused?
    assert Process.kill(0, pid)
  end

  def test_set_after_rejects_unknown_actions
    refute @control.set_after("explode")
    assert @control.set_after("reboot_after_all")
    assert_equal "reboot_after_all", @control.snapshot[:after_action]
    assert @control.set_after("none")
  end

  def test_after_current_fires_only_when_no_job_is_busy
    @control.job_started
    @control.set_after("shutdown_after_current")
    @control.send(:check_after)
    assert_empty @power.calls

    @control.job_finished
    @control.send(:check_after)
    assert_equal [:poweroff], @power.calls
    assert_equal "none", @control.snapshot[:after_action]
  end

  def test_after_all_waits_for_idle_grace
    @control.set_after("reboot_after_all")
    @control.send(:check_after)
    assert_empty @power.calls
    @control.instance_variable_set(:@idle_since, Time.now - Vaks::Control::IDLE_GRACE - 1)
    @control.send(:check_after)
    assert_equal [:reboot], @power.calls
  end

  def test_power_failure_is_reported_and_resets_action
    @power.define_singleton_method(:call) { |_| raise "polkit denied" }
    @control.set_after("shutdown_after_current")
    @control.send(:check_after)
    snap = @control.snapshot
    assert_equal "none", snap[:after_action]
    assert_equal "polkit denied", snap[:power_error]
  end
end
