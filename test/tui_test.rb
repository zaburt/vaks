require_relative "test_helper"
require "vaks/tui"

class TuiTest < Minitest::Test
  T = Vaks::TUI

  def test_text_width_ignores_escapes_and_counts_wide_chars
    assert_equal 5, T::Text.width("\e[1mhello\e[0m")
    assert_equal 4, T::Text.width("日本")
  end

  def test_fit_pads_and_truncates_to_exact_width
    assert_equal 8, T::Text.width(T::Text.fit("abc", 8))
    cut = T::Text.fit("\e[31mabcdefghij\e[0m", 6)
    assert_equal 6, T::Text.width(cut)
    assert_includes cut, "…"
    assert_equal 6, T::Text.width(T::Text.fit("日本語日本語", 6))
  end

  def test_formatters
    assert_equal "01:05", T::Text.duration(65)
    assert_equal "1:01:05", T::Text.duration(3665)
    assert_equal "--:--", T::Text.duration(nil)
    assert_equal "1.5 KiB", T::Text.size(1536)
    assert_in_delta 1.6, T::Text.parse_speed("1.6x")
    assert_equal "5m ago", T::Text.ago(1000, 1300)
  end

  def test_key_parser
    assert_equal %w[up down enter], T::Keys.parse("\e[A\e[B\r")
    assert_equal ["esc"], T::Keys.parse("\e")
    assert_equal %w[j shift+tab backspace], T::Keys.parse("j\e[Z\x7f")
    assert_equal ["日"], T::Keys.parse("日")
  end

  def test_form_edits_and_reports_changes
    fields = [T::Form::Field.new(key: "codec_video", label: "v", value: +"x264", original: "x264"),
              T::Form::Field.new(key: "delay", label: "d", value: +"5", original: "5")]
    form = T::Form.new(title: "t", fields: fields)
    assert_empty form.changes
    "ab".each_char { |c| form.handle(c) }
    form.handle("tab")
    form.handle("ctrl+u")
    assert_equal({ "codec_video" => "x264ab", "delay" => nil }, form.changes)
    assert_equal :cancel, form.handle("esc")
    assert_equal :submit, form.handle("ctrl+s")
  end

  def test_watch_params_split_profile_and_ints
    params = T::WatchParams.build("/m", { "codec_video" => "libx265", "delay" => "3", "done_dir" => nil }, keep_nil: false)
    assert_equal({ "path" => "/m", "delay" => 3, "profile" => { "codec_video" => "libx265" } }, params)
    cleared = T::WatchParams.build("/m", { "resolution" => nil }, keep_nil: true)
    assert_equal({ "resolution" => nil }, cleared["profile"])
    assert_raises(ArgumentError) { T::WatchParams.build("/m", { "delay" => "x" }, keep_nil: false) }
  end

  Notifier = Struct.new(:calls) do
    def call(title, body) = calls << [title, body]
  end

  def app(notifier = Notifier.new([]))
    source = T::Source.new(name: "t", client: nil, remote: false)
    T::App.new(sources: [source], notifier: notifier)
  end

  def snapshot(events)
    { loaded: true, status: { "running" => [], "queued" => 0, "watches" => 1, "config" => { "workers" => 2 } },
      queue: { "jobs" => [] }, watches: { "watches" => [] },
      history: { "events" => events, "stats" => { "succeeded" => events.size, "failed" => 0, "space_saved" => 0 } } }
  end

  def event(path, ok: true)
    { "path" => path, "success" => ok, "finished_at" => 1, "duration" => 5, "size_before" => 10, "size_after" => 5, "error" => ok ? nil : "boom" }
  end

  def test_notifies_only_for_jobs_finished_after_the_first_load
    notifier = Notifier.new([])
    a = app(notifier)
    a.instance_variable_set(:@snap, snapshot([event("/m/old.mkv")]))
    a.load_data
    assert_empty notifier.calls

    a.instance_variable_set(:@snap, snapshot([event("/m/new.mkv"), event("/m/bad.mkv", ok: false), event("/m/old.mkv")]))
    a.load_data
    assert_equal [["vaks: finished", "new.mkv"], ["vaks: failed", "bad.mkv"]], notifier.calls.sort_by(&:first).reverse
  end

  def test_muted_suppresses_notifications
    notifier = Notifier.new([])
    a = app(notifier)
    a.instance_variable_set(:@snap, snapshot([]))
    a.load_data
    a.handle("m")
    a.instance_variable_set(:@snap, snapshot([event("/m/new.mkv")]))
    a.load_data
    assert_empty notifier.calls
  end

  def test_frame_fills_the_terminal_exactly
    a = app
    snap = snapshot([event("/m/日本語.mkv")])
    snap[:status]["running"] = [{ "path" => "/m/a.mkv", "elapsed" => 30.0, "fps" => 40.0, "speed" => "2.0x", "duration" => 120 }]
    snap[:queue]["jobs"] = [{ "path" => "/m/b.mkv", "watch" => "inbox", "priority" => 1, "duration" => 60 }]
    a.instance_variable_set(:@snap, snap)
    a.load_data
    [[24, 80], [10, 40], [40, 140]].each do |rows, cols|
      frame = a.build_frame(rows, cols)
      assert_equal rows, frame.length
      assert(frame.all? { |l| T::Text.width(l) == cols }, "lines must be #{cols} wide")
    end
    a.handle("?")
    assert_equal 24, a.build_frame(24, 80).length
  end
end
