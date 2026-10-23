module Vaks
  module TUI
    # Drawing: turns the App's current data and UI state into an array of screen lines.
    module View
      include Text

      RULE = "─"

      def build_frame(rows, cols)
        lines = case @mode
                when :form then form_screen(rows, cols)
                when :menu then menu_screen(rows, cols)
                when :help then help_screen(rows, cols)
                else main_screen(rows, cols)
                end
        lines = lines.first(rows)
        lines << "" while lines.length < rows
        lines.map { |l| Text.fit(l, cols) }
      end

      private

      def main_screen(rows, cols)
        avail    = rows - 4
        run_h    = 1 + @running.size.clamp(1, 6)
        queue_h  = 1 + @queue.size.clamp(1, [(avail - run_h - 4) / 2, 1].max)
        bottom_h = [avail - run_h - queue_h, 2].max

        lines = [header_line(cols), stats_line]
        lines += section("Running (#{@running.size})", running_rows(cols), run_h, :running, cols)
        lines += section("Queue (#{@queue.size})", queue_rows(cols), queue_h, :queue, cols)
        lines += section(pane_tabs, bottom_rows(cols), bottom_h, :bottom, cols)
        lines << message_line
        lines << hint_line
      end

      def header_line(cols)
        snap = @snap
        dot  = snap[:error] || !snap[:loaded] ? Text.style("●", 31) : Text.style("●", 32)
        left = " #{Text.style("vaks", 1, 35)}  #{dot} #{Text.style(@source.name, 1)}"
        left += Text.style("  (#{@source.client.uri})", 90) if @source.remote?
        right = []
        right << Text.style(" PAUSED ", 1, 30, 43) if status["paused"]
        right << Text.style(" STOPPED ", 1, 37, 41) if status["stopped"]
        right << Text.style(" #{after_label} ", 1, 37, 41) if after_label
        right << Text.style("muted", 90) if @muted
        workers = status.dig("config", "workers")
        right << Text.style("workers #{workers}", 90) if workers
        right = right.join("  ") + " "
        gap = cols - Text.width(left) - Text.width(right)
        left + " " * [gap, 1].max + right
      end

      def after_label
        a = status["after_action"]
        return nil if a.nil? || a == "none"
        a.tr("_", " ")
      end

      def stats_line
        return " " + Text.style("cannot reach daemon: #{@snap[:error]} — retrying", 31) if @snap[:error]
        return " " + Text.style("connecting…", 90) unless @snap[:loaded] && status.any?
        st = @snap.dig(:history, "stats") || {}
        parts = ["Queued #{status["queued"]}", "Running #{@running.size}", "Watches #{status["watches"]}"]
        parts << "Done #{st["succeeded"]}" if st["succeeded"]
        parts << "Failed #{st["failed"]}" if st["failed"].to_i.positive?
        parts << "Saved #{Text.size(st["space_saved"])}" if st["space_saved"].to_i.positive?
        " " + Text.style(parts.join("  ·  "), 90)
      end

      def section(title, body, height, focus, cols)
        focused = @focus == focus
        text  = focused ? Text.style(title, 1, 36) : title
        color = focused ? "\e[36m" : "\e[90m"
        rule  = RULE * 2 + " " + text + " "
        fill  = RULE * [cols - Text.width(rule), 0].max
        lines = [color + RULE * 2 + " \e[0m" + text + color + " " + fill + "\e[0m"]
        rows_avail = height - 1
        tail_view = focus == :bottom && @pane == :output
        cursor = @cur[focus]
        top = tail_view ? [body.size - rows_avail, 0].max : (cursor < rows_avail ? 0 : cursor - rows_avail + 1)
        visible = body[top, rows_avail] || []
        visible.each_with_index do |line, i|
          selected = focused && !tail_view && top + i == cursor
          lines << (selected ? "\e[7m" + Text.fit(line, cols).gsub("\e[0m", "\e[0;7m") + "\e[0m" : line)
        end
        lines << "" while lines.length < height
        lines
      end

      def running_rows(cols)
        return [Text.style("  nothing running", 90)] if @running.empty?
        @running.map do |job|
          duration = job["duration"]
          elapsed  = job["elapsed"].to_f
          frac     = duration && duration.to_f.positive? ? elapsed / duration : nil
          speed    = Text.parse_speed(job["speed"])
          speed    = @avg_speed if speed.zero?
          eta      = duration && speed.positive? ? [duration - elapsed, 0].max / speed : nil
          icon     = status["paused"] ? "⏸" : "▶"
          bar      = frac ? Text.bar(frac, 14) : "░" * 14
          pct      = frac ? format("%3d%%", (frac * 100).round) : "  --"
          fps      = job["fps"] ? format("%5.1ffps", job["fps"]) : "       "
          tail     = "#{bar} #{pct} #{fps} #{format("%6s", job["speed"] || "")} ETA #{Text.duration(eta)}"
          name     = Text.fit(File.basename(job["path"].to_s), [cols - Text.width(tail) - 5, 8].max)
          " #{icon} #{name} #{tail}"
        end
      end

      def queue_rows(cols)
        return [Text.style("  queue is empty", 90)] if @queue.empty?
        @queue.each_with_index.map do |job, i|
          est  = job["duration"] && @avg_speed.positive? ? "~#{Text.duration(job["duration"] / @avg_speed)}" : ""
          prio = job["priority"].to_i.zero? ? "" : "p#{job["priority"]}"
          tail = "#{format("%-14s", job["watch"].to_s[0, 14])} #{format("%3s", prio)} #{format("%9s", est)}"
          name = Text.fit(File.basename(job["path"].to_s), [cols - tail.length - 8, 8].max)
          format(" %3d. ", i + 1) + "#{name} #{tail}"
        end
      end

      def pane_tabs
        { history: "1 History", watches: "2 Watches", output: "3 Output" }.map do |k, label|
          k == @pane ? Text.style(label, 1, 33) : label
        end.join("   ")
      end

      def bottom_rows(cols)
        case @pane
        when :history then history_rows(cols)
        when :watches then watch_rows(cols)
        else output_rows
        end
      end

      def history_rows(cols)
        return [Text.style("  no jobs finished yet", 90)] if @events.empty?
        now = Time.now.to_i
        @events.map do |e|
          mark = e["success"] ? Text.style("✔", 32) : Text.style("✘", 31)
          detail =
            if e["success"]
              before, after = e["size_before"], e["size_after"]
              ratio = before.to_i.positive? && after ? format("%+d%%", ((after.to_f / before - 1) * 100).round) : ""
              "#{Text.size(before)} → #{Text.size(after)} #{ratio}"
            else
              Text.style(e["error"].to_s.lines.first.to_s.strip, 31)
            end
          tail = "#{Text.pad_left(Text.duration(e["duration"]), 8)}  #{Text.pad_left(Text.ago(e["finished_at"], now), 8)}"
          name = Text.fit(File.basename(e["path"].to_s), [(cols - 40) / 2, 10].max)
          " #{mark} #{name} #{tail}  #{detail}"
        end
      end

      def watch_rows(cols)
        return [Text.style("  no watches — press n to add one", 90)] if @watches.empty?
        @watches.map do |w|
          p = w["profile"] || {}
          enabled = w.fetch("enabled", true)
          mark = enabled ? Text.style("▶", 32) : Text.style("⏸", 33)
          codecs = [w["profile_preset"], p["codec_video"], p["codec_audio"], p["resolution"]].compact.join(" ")
          prio = w["priority"].to_i.zero? ? "" : "p#{w["priority"]}"
          tail = "#{codecs} #{prio}".strip
          path = Text.fit(w["path"].to_s, [cols - Text.width(tail) - 6, 10].max)
          " #{mark} #{path} #{Text.style(tail, 90)}"
        end
      end

      def output_rows
        out = @snap[:output]
        return [Text.style("  select a running job and press Enter (or 3)", 90)] unless @output_path
        return [Text.style("  #{out["error"]}", 31)] if out && out["error"]
        lines = (out && out["output"] || []).map { |l| " " + l.to_s.tr("\r\t", "  ").gsub(/\e\[[0-9;]*[A-Za-z]/, "") }
        lines.empty? ? [Text.style("  waiting for output from #{File.basename(@output_path)}…", 90)] : lines
      end

      def message_line
        return " " + @confirm[:text] if @mode == :confirm
        return "" unless @flash && @flash[:until] > Time.now.to_f
        " " + Text.style(@flash[:text], @flash[:error] ? 31 : 32)
      end

      def hint_line
        keys = case @focus
               when :running then "Enter output · s stop job · S stop all"
               when :queue then "J/K reorder · x flush"
               else
                 case @pane
                 when :watches then "n new · e edit · D remove · space on/off"
                 when :history then "t retry failed"
                 else "Enter on a running job"
                 end
               end
        Text.style(" #{keys} │ Tab focus · p pause · s stop · a after · ? help · q quit", 90)
      end

      # --- modal screens ---

      def centered(lines, rows, cols, title: nil)
        inner = [[lines.map { |l| Text.width(l) }.max.to_i, Text.width(title.to_s) + 2].max + 2, cols - 4].min
        top = "┌─ #{title} " + "─" * [inner - Text.width(title.to_s) - 3, 0].max + "┐"
        body = lines.map { |l| "│ " + Text.fit(l, inner - 2) + " │" }
        box = [top, *body, "└" + "─" * inner + "┘"]
        margin = " " * [(cols - inner - 2) / 2, 0].max
        pad = [(rows - box.length) / 2, 0].max
        [""] * pad + box.map { |l| margin + l }
      end

      def form_screen(rows, cols)
        f = @form
        label_w = f.fields.map { |x| x.label.length }.max
        lines = f.fields.each_with_index.map do |fld, i|
          active = i == f.index
          value = fld.value + (active ? "▏" : "")
          label = format("%-#{label_w}s", fld.label)
          line = "#{active ? Text.style(label, 1, 36) : label}  #{value}"
          line
        end
        lines << ""
        lines << Text.style(f.current.hint.to_s, 90)
        lines << (f.error ? Text.style(f.error, 31) : "")
        lines << Text.style("Enter/Tab next · ctrl+s save · Esc cancel · ctrl+u clear", 90)
        centered(lines, rows, cols, title: f.title)
      end

      def menu_screen(rows, cols)
        current = status["after_action"] || "none"
        lines = AFTER_ACTIONS.each_with_index.map do |(value, label), i|
          text = "#{i + 1}  #{value == current ? "●" : "○"} #{label}"
          i == @menu_index ? Text.style(text, 7) : text
        end
        lines << ""
        lines << Text.style("j/k or 1-5 choose · Enter apply · Esc cancel", 90)
        centered(lines, rows, cols, title: "When the queue finishes")
      end

      HELP = [
        ["Tab / Shift+Tab", "move focus between Running, Queue and the bottom pane"],
        ["j k ↑ ↓  PgUp PgDn", "move the selection"],
        ["1 2 3", "bottom pane: History / Watches / Output"],
        ["Enter", "on a running job: show its ffmpeg output"],
        ["p", "pause / continue all running jobs (freezes ffmpeg)"],
        ["s / S", "stop the selected job / all jobs (holds the queue)"],
        ["r", "resume the queue after a stop"],
        ["x / d", "flush the queue / drain (finish and shut the daemon down)"],
        ["J / K", "move the selected queued job down / up"],
        ["t", "retry the selected failed job (History)"],
        ["n e D space", "Watches: new, edit, remove, suspend/resume"],
        ["+ / -", "add / remove a worker"],
        ["a", "power action once the queue finishes"],
        ["m", "mute desktop notifications (this session)"],
        ["[ / ]", "previous / next daemon (remotes.yml)"],
        ["q", "quit"]
      ].freeze

      def help_screen(rows, cols)
        keyw = HELP.map { |k, _| k.length }.max
        lines = HELP.map { |k, d| "#{Text.style(format("%-#{keyw}s", k), 36)}  #{d}" }
        lines << ""
        lines << Text.style("any key to close", 90)
        centered(lines, rows, cols, title: "vakstui")
      end
    end
  end
end
