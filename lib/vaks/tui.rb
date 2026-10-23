require "io/console"
require_relative "tui/text"
require_relative "tui/keys"
require_relative "tui/form"
require_relative "tui/source"
require_relative "tui/view"

module Vaks
  module TUI
    AFTER_ACTIONS = [
      ["none", "Do nothing"],
      ["shutdown_after_current", "Shut down after the current job"],
      ["shutdown_after_all", "Shut down when the queue is empty"],
      ["reboot_after_current", "Reboot after the current job"],
      ["reboot_after_all", "Reboot when the queue is empty"]
    ].freeze

    # Desktop notification through notify-send, when installed.
    module Notifier
      module_function

      def available? = ENV["PATH"].to_s.split(":").any? { |d| File.executable?(File.join(d, "notify-send")) }

      def call(title, body)
        return unless available?
        pid = Process.spawn("notify-send", "-a", "vaks", title, body, %i[out err] => File::NULL)
        Process.detach(pid)
      rescue SystemCallError
        nil
      end
    end

    class App
      include View

      FOCUS = %i[running queue bottom].freeze
      PAGE  = 10

      def initialize(sources:, notifier: Notifier, input: $stdin, output: $stdout)
        @sources  = sources
        @src_i    = 0
        @source   = sources.first
        @notifier = notifier
        @in       = input
        @out      = output
        @poller   = Poller.new(@source)
        @mode     = :normal
        @focus    = :running
        @pane     = :history
        @cur      = { running: 0, queue: 0, bottom: 0 }
        @muted    = false
        @flash    = nil
        @seen     = nil
        @snap     = {}
        @running = @queue = @watches = @events = []
        @avg_speed = 0.0
        @output_path = nil
        @dirty = true
      end

      def run
        @poller.start
        trap("WINCH") { @dirty = true }
        trap("TERM") { @quit = true }
        @out.print "\e[?1049h\e[?25l"
        @in.raw { loop_until_quit }
      ensure
        @poller.stop
        @out.print "\e[?25h\e[?1049l"
      end

      def loop_until_quit
        until @quit
          @snap = @poller.snapshot
          load_data
          draw
          next unless IO.select([@in], nil, nil, 0.2)
          chunk = @in.read_nonblock(1024, exception: false)
          break if chunk.nil?
          next if chunk == :wait_readable
          Keys.parse(chunk).each { |k| handle(k) }
        end
      end

      # --- data ---

      def status = @snap[:status] || {}

      def load_data
        @running = status["running"] || []
        @queue   = @snap.dig(:queue, "jobs") || []
        @watches = @snap.dig(:watches, "watches") || []
        @events  = @snap.dig(:history, "events") || []
        speeds   = @running.map { |j| Text.parse_speed(j["speed"]) }.select(&:positive?)
        @avg_speed = speeds.empty? ? 0.0 : speeds.sum / speeds.length
        clamp_cursors
        detect_finished
      end

      def clamp_cursors
        { running: @running.size, queue: @queue.size, bottom: bottom_items.size }.each do |k, n|
          @cur[k] = @cur[k].clamp(0, [n - 1, 0].max)
        end
      end

      def bottom_items
        case @pane
        when :history then @events
        when :watches then @watches
        else []
        end
      end

      # New history entries after the first load are job completions worth announcing.
      def detect_finished
        return unless @snap[:history].is_a?(Hash) && @snap.dig(:history, "events")
        keys = @events.map { |e| [e["path"], e["finished_at"]] }
        if @seen.nil?
          @seen = keys
          return
        end
        (keys - @seen).each do |key|
          e = @events.find { |x| [x["path"], x["finished_at"]] == key }
          announce(e)
        end
        @seen = keys
      end

      def announce(event)
        name = File.basename(event["path"].to_s)
        if event["success"]
          flash("Finished #{name}")
          @notifier.call("vaks: finished", name) unless @muted
        else
          flash("Failed #{name}: #{event["error"].to_s.lines.first.to_s.strip}", error: true)
          @notifier.call("vaks: failed", name) unless @muted
        end
      end

      # --- drawing ---

      def draw
        rows, cols = @out.winsize rescue [24, 80]
        frame = build_frame(rows, cols).join("\r\n")
        return if frame == @last_frame && !@dirty
        @dirty = false
        @last_frame = frame
        @out.print "\e[H#{frame.gsub("\r\n", "\e[K\r\n")}\e[K\e[J"
        @out.flush
      end

      def flash(text, error: false)
        @flash = { text: text, error: error, until: Time.now.to_f + 6 }
      end

      # --- input ---

      def handle(key)
        @dirty = true
        case @mode
        when :form then handle_form(key)
        when :menu then handle_menu(key)
        when :help then @mode = :normal
        when :confirm then handle_confirm(key)
        else handle_normal(key)
        end
      end

      def handle_normal(key)
        case key
        when "q", "ctrl+c" then @quit = true
        when "?" then @mode = :help
        when "ctrl+l" then @last_frame = nil
        when "tab" then cycle_focus(1)
        when "shift+tab" then cycle_focus(-1)
        when "j", "down" then move(1)
        when "k", "up" then move(-1)
        when "pgdn" then move(PAGE)
        when "pgup" then move(-PAGE)
        when "home" then move(-10_000)
        when "end" then move(10_000)
        when "1" then show_pane(:history)
        when "2" then show_pane(:watches)
        when "3" then show_pane(:output)
        when "enter" then open_output if @focus == :running
        when "p" then toggle_pause
        when "r" then act("resume", "Queue resumed")
        when "s" then stop_selected
        when "S" then ask("Stop ALL running jobs? (kills ffmpeg, holds the queue) [y/N]") { act("stop-job", "Stopped all jobs", all: true) }
        when "x" then ask("Remove all #{@queue.size} queued jobs? [y/N]") { act("flush-queue", "Queue flushed") }
        when "d" then ask("Drain: finish running jobs, then shut the daemon down? [y/N]") { act("drain", "Draining") }
        when "J" then reorder(1)
        when "K" then reorder(-1)
        when "t" then retry_selected
        when "+", "=" then change_workers(1)
        when "-", "_" then change_workers(-1)
        when "a" then open_menu
        when "m"
          @muted = !@muted
          flash(@muted ? "Notifications muted" : "Notifications on")
        when "[" then switch_source(-1)
        when "]" then switch_source(1)
        when "n" then new_watch if watches_focused?
        when "e" then edit_watch if watches_focused?
        when "D" then remove_watch if watches_focused?
        when " " then toggle_watch if watches_focused?
        end
      end

      def watches_focused? = @focus == :bottom && @pane == :watches

      def cycle_focus(step)
        @focus = FOCUS[(FOCUS.index(@focus) + step) % FOCUS.length]
      end

      def move(delta)
        @cur[@focus] = (@cur[@focus] + delta).clamp(0, [list_size(@focus) - 1, 0].max)
      end

      def list_size(focus)
        { running: @running.size, queue: @queue.size, bottom: bottom_items.size }[focus]
      end

      def show_pane(pane)
        @pane = pane
        @focus = :bottom
        @cur[:bottom] = 0
        if pane == :output
          open_output(@running[@cur[:running]])
        else
          @output_path = nil
          @poller.watch_output(nil)
        end
      end

      def open_output(job = @running[@cur[:running]])
        @pane = :output
        @focus = :bottom
        @output_path = job && job["path"]
        @poller.watch_output(@output_path)
      end

      # --- commands (run off the UI thread so a slow daemon never freezes the screen) ---

      def async
        Thread.new do
          yield
        rescue => e
          flash(e.message, error: true)
        ensure
          @dirty = true
          @poller.refresh
        end
      end

      def act(cmd, done, **args)
        async do
          res = @source.send(cmd, **args)
          res["error"] ? flash(res["error"], error: true) : flash(done)
        end
      end

      def ask(text, &action)
        @confirm = { text: text, action: action }
        @mode = :confirm
      end

      def handle_confirm(key)
        action = @confirm[:action]
        @mode = :normal
        @confirm = nil
        action.call if key.downcase == "y"
      end

      def toggle_pause
        if status["paused"]
          act("unpause", "Continued")
        else
          act("pause", "Paused", all: true)
        end
      end

      def stop_selected
        job = @focus == :running && @running[@cur[:running]]
        return flash("Select a running job first (Tab to the Running list)", error: true) unless job
        name = File.basename(job["path"])
        ask("Stop #{name}? (kills ffmpeg, holds the queue) [y/N]") { act("stop-job", "Stopped #{name}", path: job["path"]) }
      end

      def reorder(delta)
        return unless @focus == :queue
        i = @cur[:queue]
        j = i + delta
        return if j.negative? || j >= @queue.size
        paths = @queue.map { |q| q["path"] }
        paths[i], paths[j] = paths[j], paths[i]
        @cur[:queue] = j
        act("queue-reorder", "Moved", paths: paths)
      end

      def retry_selected
        return unless @focus == :bottom && @pane == :history
        e = @events[@cur[:bottom]]
        return flash("Select a failed job", error: true) if e.nil? || e["success"]
        act("retry-job", "Re-queued #{File.basename(e["path"])}", path: e["path"])
      end

      def change_workers(delta)
        current = status.dig("config", "workers")
        return flash("Worker count unknown (daemon too old?)", error: true) unless current
        wanted = current + delta
        return flash("At least one worker is required", error: true) if wanted < 1
        act("config", "Workers: #{wanted}", workers: wanted)
      end

      def switch_source(step)
        return flash("Only one daemon configured (see remotes.yml)") if @sources.length < 2
        @src_i = (@src_i + step) % @sources.length
        @source = @sources[@src_i]
        @seen = nil
        @cur = { running: 0, queue: 0, bottom: 0 }
        @output_path = nil
        @poller.watch_output(nil)
        @poller.use(@source)
        flash("Switched to #{@source.name}")
      end

      # --- power menu ---

      def open_menu
        current = status["after_action"] || "none"
        @menu_index = AFTER_ACTIONS.index { |v, _| v == current } || 0
        @mode = :menu
      end

      def handle_menu(key)
        case key
        when "esc", "q" then @mode = :normal
        when "j", "down" then @menu_index = (@menu_index + 1) % AFTER_ACTIONS.length
        when "k", "up" then @menu_index = (@menu_index - 1) % AFTER_ACTIONS.length
        when /\A[1-5]\z/ then apply_menu(key.to_i - 1)
        when "enter" then apply_menu(@menu_index)
        end
      end

      def apply_menu(index)
        @mode = :normal
        value, label = AFTER_ACTIONS[index]
        act("power", label, action: value)
      end

      # --- watch forms ---

      FORM_FIELDS = [
        ["profile_preset", "preset", "Named preset from config.yml (e.g. 1080p-h265)"],
        ["codec_video", "video codec", "ffmpeg video codec, e.g. libx265"],
        ["codec_audio", "audio codec", "ffmpeg audio codec, e.g. aac"],
        ["codec_subtitle", "subtitle codec", "e.g. copy or mov_text"],
        ["resolution", "resolution", "e.g. 1280x720"],
        ["extra_args", "extra args", "extra ffmpeg arguments"],
        ["done_dir", "done dir", "where converted files go (relative to the watch)"],
        ["error_dir", "error dir", "where failed files go"],
        ["delay", "delay (s)", "seconds to wait before a new file is picked up"],
        ["priority", "priority", "higher runs first (integer)"],
        ["retries", "retries", "attempts before a file is moved to error"]
      ].freeze

      def new_watch
        fields = [Form::Field.new(key: "path", label: "path", value: +"", original: "",
                                  hint: "absolute directory on #{@source.name}")]
        fields += FORM_FIELDS.map { |k, l, h| Form::Field.new(key: k, label: l, value: +"", original: "", hint: h) }
        @form = Form.new(title: "New watch on #{@source.name}", fields: fields)
        @form_action = :add
        @mode = :form
      end

      def edit_watch
        w = @watches[@cur[:bottom]] or return
        profile = w["profile"] || {}
        fields = FORM_FIELDS.map do |k, l, h|
          v = (profile.key?(k) ? profile[k] : w[k]).to_s
          Form::Field.new(key: k, label: l, value: v.dup, original: v, hint: h)
        end
        @form = Form.new(title: "Edit #{w["path"]}", fields: fields)
        @form_path = w["path"]
        @form_action = :update
        @mode = :form
      end

      def handle_form(key)
        result = @form.handle(key)
        case result
        when :cancel then close_form
        when :submit then submit_form
        end
      end

      def close_form
        @mode = :normal
        @form = nil
      end

      def submit_form
        form = @form
        if @form_action == :add
          path = form.fields.first.value.strip
          return form.error = "path is required" if path.empty?
          params = WatchParams.build(path, form.changes.reject { |k, _| k == "path" }, keep_nil: false)
        else
          changes = form.changes
          return close_form if changes.empty?
          params = WatchParams.build(@form_path, changes, keep_nil: true)
        end
        action = @form_action
        async do
          res = @source.manage_watch(action, params)
          if res["error"]
            form.error = res["error"]
          else
            close_form if @form.equal?(form)
            flash(action == :add ? "Watch added: #{params["path"]}" : "Watch updated")
          end
        end
      rescue ArgumentError => e
        form.error = e.message
      end

      def remove_watch
        w = @watches[@cur[:bottom]] or return
        ask("Remove watch #{w["path"]}? (config file is deleted) [y/N]") do
          async do
            res = @source.manage_watch(:remove, { "path" => w["path"] })
            res["error"] ? flash(res["error"], error: true) : flash("Watch removed")
          end
        end
      end

      def toggle_watch
        w = @watches[@cur[:bottom]] or return
        enabled = !w.fetch("enabled", true)
        act("watch-toggle", enabled ? "Watch resumed" : "Watch suspended", path: w["path"], enabled: enabled)
      end
    end
  end
end
