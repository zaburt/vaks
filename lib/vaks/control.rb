module Vaks
  # Runtime run-state shared by the workers, the control servers and the daemon:
  #
  #  * stopped  — the user hit "stop": running ffmpeg processes are SIGKILLed on the spot
  #               and no new job starts until #resume. Killed jobs go back to the queue
  #               and restart from scratch; they are never moved to error/.
  #  * paused   — ffmpeg processes are frozen with SIGSTOP and continue exactly where they
  #               were on #unpause (SIGCONT); no new job starts meanwhile. Nothing restarts.
  #  * after    — what to do with the machine once work finishes (see AFTER_ACTIONS).
  #               Changeable at any time; "none" cancels a pending action.
  class Control
    AFTER_ACTIONS = %w[none shutdown_after_all reboot_after_all
                       shutdown_after_current reboot_after_current].freeze

    # Queue must stay empty and idle this long before an *_after_all action fires, so a
    # file that is about to be picked up by a watcher isn't missed.
    IDLE_GRACE = 10
    TICK       = 2

    attr_reader :after, :power_error

    def initialize(queue:, in_flight:, pid_map:, mutex:, logger:, power: Power)
      @queue     = queue
      @in_flight = in_flight
      @pid_map   = pid_map
      @mutex     = mutex
      @logger    = logger
      @power     = power
      @cond      = ConditionVariable.new
      @stopped   = false
      @paused    = false
      @closing   = false
      @killed    = Set.new
      @busy      = 0
      @after     = "none"
      @hold      = false
      @idle_since = nil
      @power_error = nil
    end

    def stopped?
      @mutex.synchronize { @stopped }
    end

    def paused?
      @mutex.synchronize { @paused }
    end

    def snapshot
      @mutex.synchronize { { stopped: @stopped, paused: @paused, after_action: @after, power_error: @power_error } }
    end

    # ── stop / resume ───────────────────────────────────────────────────────

    # SIGKILLs the ffmpeg for `path` (or every running one with all: true) and holds the
    # queue. Returns the number of processes killed.
    def stop(path: nil, all: false)
      pids = @mutex.synchronize do
        @stopped = true
        @paused  = false
        targets = all ? @pid_map.keys : [path].compact
        targets.filter_map do |p|
          pid = @pid_map.dig(p, :pid)
          next unless pid
          @killed << p
          [p, pid]
        end
      end

      killed = 0
      pids.each do |p, pid|
        Process.kill("KILL", pid)
        killed += 1
        @logger.info "Stop: killed ffmpeg PID #{pid} (#{File.basename(p)})"
      rescue Errno::ESRCH
        @mutex.synchronize { @killed.delete(p) }
      end
      @logger.info "Stopped — queue on hold until resumed" if killed.zero?
      killed
    end

    # Releases both stop and pause: thaws any frozen ffmpeg and lets the queue run again.
    def resume
      unpause
      @mutex.synchronize do
        @stopped = false
        @cond.broadcast
      end
      @logger.info "Resumed"
    end

    # ── pause / unpause ─────────────────────────────────────────────────────

    # Freezes ffmpeg for `path` (or every running one with all: true) with SIGSTOP and holds
    # the queue. Returns the number of processes frozen.
    def pause(path: nil, all: false)
      targets = @mutex.synchronize do
        @paused = true
        all ? @pid_map.keys : [path].compact
      end
      frozen = targets.count { |p| signal_job(p, "STOP", paused: true) }
      @logger.info "Paused: #{frozen} job(s) frozen — queue on hold until unpaused"
      frozen
    end

    # Continues every frozen ffmpeg exactly where it left off and releases the queue.
    def unpause
      targets = @mutex.synchronize { @paused = false; @pid_map.select { |_, i| i[:paused] }.keys }
      targets.each { |p| signal_job(p, "CONT", paused: false) }
      @mutex.synchronize { @cond.broadcast }
      @logger.info "Unpaused: #{targets.length} job(s) continued"
      targets.length
    end

    # Called by a worker right after ffmpeg spawns, so a job that started while the daemon
    # is paused is frozen too.
    def job_spawned(path)
      signal_job(path, "STOP", paused: true) if paused?
    end

    # True (once) if the user's stop killed this job's ffmpeg.
    def consume_kill(path)
      @mutex.synchronize { @killed.delete?(path) }
    end

    # ── worker hooks ────────────────────────────────────────────────────────

    def held?
      @mutex.synchronize { @stopped || @paused || @hold }
    end

    # Blocks while the queue is on hold. Returns false if the daemon is closing.
    def wait_while_held
      @mutex.synchronize do
        @cond.wait(@mutex) while (@stopped || @paused || @hold) && !@closing
        !@closing
      end
    end

    def job_started  = @mutex.synchronize { @busy += 1 }
    def job_finished = @mutex.synchronize { @busy -= 1 }

    # Daemon is shutting down: wake held workers and thaw frozen jobs so they can finish.
    def close
      frozen = @mutex.synchronize do
        @closing = true
        @paused  = false
        @cond.broadcast
        @pid_map.select { |_, i| i[:paused] }.keys
      end
      frozen.each { |p| signal_job(p, "CONT", paused: false) }
    end

    # ── after-process action ────────────────────────────────────────────────

    # Returns true if the action was accepted.
    def set_after(action)
      action = action.to_s
      return false unless AFTER_ACTIONS.include?(action)

      @mutex.synchronize do
        @after       = action
        @power_error = nil
        @idle_since  = nil
        @hold        = action.end_with?("_after_current")
        @cond.broadcast unless @hold
      end
      @logger.info "After-process action: #{action}"
      true
    end

    def start_monitor
      Thread.new do
        loop do
          sleep TICK
          break if @closing
          check_after
        end
      rescue => e
        @logger.error "Power monitor crashed: #{e.message}"
      end
    end

    private

    # Sends `sig` to the job's ffmpeg and records its paused state in pid_map (shown in status).
    def signal_job(path, sig, paused:)
      pid = @mutex.synchronize { @pid_map.dig(path, :pid) }
      return false unless pid

      Process.kill(sig, pid)
      @mutex.synchronize { @pid_map[path][:paused] = paused if @pid_map[path] }
      true
    rescue Errno::ESRCH
      false
    end

    def check_after
      action, due = @mutex.synchronize do
        case @after
        when "none"
          [nil, false]
        when "shutdown_after_current", "reboot_after_current"
          [@after, @busy.zero?]
        else
          idle = @queue.empty? && @in_flight.empty? && @busy.zero? && !@stopped
          @idle_since = idle ? (@idle_since || Time.now) : nil
          [@after, idle && Time.now - @idle_since >= IDLE_GRACE]
        end
      end
      fire(action) if due
    end

    def fire(action)
      kind = action.start_with?("reboot") ? :reboot : :poweroff
      @logger.info "Work finished — requesting #{kind} via logind"
      @mutex.synchronize { @after = "none"; @hold = false; @idle_since = nil; @cond.broadcast }
      @power.call(kind)
    rescue => e
      @logger.error "#{kind} failed: #{e.message}"
      @mutex.synchronize { @power_error = e.message; @cond.broadcast }
    end
  end
end
