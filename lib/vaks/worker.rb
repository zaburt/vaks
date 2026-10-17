require "fileutils"

module Vaks
  class Worker
    OUTPUT_BUFFER_LINES = 200

    def initialize(queue:, in_flight:, pending_jobs:, pid_map:, mutex:, logger:, extensions:,
                   control:, history: nil, retry_delay: 5)
      @queue        = queue
      @in_flight    = in_flight
      @pending_jobs = pending_jobs
      @pid_map      = pid_map
      @mutex        = mutex
      @logger       = logger
      @extensions   = extensions
      @history      = history
      @retry_delay  = retry_delay
      @control      = control
    end

    # Start the worker in a background thread. Returns the Thread.
    def start
      Thread.new { run_loop }
    end

    private

    def run_loop
      loop do
        job = @queue.pop
        break if job == :stop

        # Queue on hold (user stop / "after current" power action): put the job back
        # untouched and sleep until released.
        if @control.held?
          @queue << job
          break unless @control.wait_while_held
          next
        end

        @mutex.synchronize { @pending_jobs.delete(job) }
        @control.job_started
        begin
          process(job)
        ensure
          @control.job_finished
        end
      end
    rescue => e
      @logger.error "Worker crashed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    end

    def process(job)
      requeued = false
      unless File.file?(job.path)
        @logger.warn "Skipping #{job.path}: no longer exists"
        release(job.path)
        return
      end

      ext = File.extname(job.path).delete_prefix(".").downcase
      unless @extensions.include?(ext)
        @logger.debug "Skipping #{job.path}: extension .#{ext} not in whitelist"
        release(job.path)
        return
      end

      # Disk-space guard: if the destination dir is too low on free space, don't burn a
      # worker slot spinning — re-queue the job and let another worker/tick try again shortly.
      target_dir = job.working_dir || job.done_dir
      if DiskSpace.low?(target_dir, job.min_free_space_mb)
        @logger.warn "Low disk space on #{target_dir} (< #{job.min_free_space_mb}MB free) — " \
                     "deferring #{File.basename(job.path)}"
        requeue_later(job)
        return
      end

      FileUtils.mkdir_p(job.done_dir)
      FileUtils.mkdir_p(job.working_dir)     if job.working_dir
      FileUtils.mkdir_p(job.source_done_dir) if job.source_done_dir
      FileUtils.mkdir_p(job.error_dir)

      if job.delay > 0
        @logger.info "Delaying #{job.delay}s before encoding: #{File.basename(job.path)}"
        sleep job.delay
      end

      encode_dir = job.working_dir || job.done_dir
      output     = File.join(encode_dir, File.basename(job.path))
      @logger.info "Starting: #{File.basename(job.path)}#{" (attempt #{job.attempt + 1})" if job.attempt > 0}"

      started_at    = Time.now
      size_before   = File.size(job.path)
      stderr_output = nil
      ffmpeg_command = nil
      success = Ffmpeg.run(job.path, output, job.profile,
                           nice: job.nice, ionice_class: job.ionice_class,
                           ionice_level: job.ionice_level) do |ev|
        case ev[:event]
        when :start
          @mutex.synchronize do
            @pid_map[job.path] = { pid: ev[:pid], started_at: Time.now.to_i, elapsed: 0.0, fps: nil, speed: nil, output: [] }
          end
          @control.job_spawned(job.path)
          @logger.debug "ffmpeg PID=#{ev[:pid]} file=#{File.basename(job.path)}"
        when :output
          @mutex.synchronize do
            buf = (@pid_map[job.path] ||= {})[:output] ||= []
            buf << ev[:line]
            buf.shift while buf.length > OUTPUT_BUFFER_LINES
          end
        when :progress
          @mutex.synchronize do
            @pid_map[job.path]&.merge!(elapsed: ev[:elapsed], fps: ev[:fps], speed: ev[:speed])
          end
        when :done
          stderr_output  = ev[:stderr]
          ffmpeg_command = ev[:command]
          @logger.debug "ffmpeg exit=#{ev[:exit_code]} file=#{File.basename(job.path)}"
        end
      end

      duration = Time.now - started_at

      if !success && @control.consume_kill(job.path)
        FileUtils.rm_f(output)
        @logger.info "Stopped by user: #{File.basename(job.path)} — back in queue, will restart from scratch"
        requeue_stopped(job)
        requeued = true
        return
      end
      @control.consume_kill(job.path)

      if success
        final_path = output
        if job.working_dir
          final = unique_path(job.done_dir, File.basename(job.path))
          FileUtils.mv(output, final, force: true)
          final_path = final
          @logger.info "Done: #{File.basename(job.path)} → #{final}"
        else
          @logger.info "Done: #{File.basename(job.path)} → #{job.done_dir}"
        end
        if job.source_done_dir
          src_dest = unique_path(job.source_done_dir, File.basename(job.path))
          FileUtils.mv(job.path, src_dest, force: true)
          @logger.info "Source: #{File.basename(job.path)} → #{src_dest}"
        end

        size_after = File.exist?(final_path) ? File.size(final_path) : nil
        record_history(job, success: true, duration: duration, size_before: size_before, size_after: size_after)
        notify_webhook(job, "success", duration: duration, size_before: size_before, size_after: size_after)
      else
        FileUtils.rm_f(output) if job.working_dir && File.exist?(output)
        save_error_log(job, ffmpeg_command, stderr_output)

        if job.attempt < job.retries
          @logger.warn "Failed: #{File.basename(job.path)} — retrying " \
                       "(attempt #{job.attempt + 1}/#{job.retries + 1})"
          record_history(job, success: false, duration: duration, size_before: size_before, size_after: nil,
                         error: "attempt #{job.attempt + 1} failed, retrying")
          requeue_retry(job)
        else
          @logger.error "Failed: #{File.basename(job.path)} — moving to #{job.error_dir}"
          dest = unique_path(job.error_dir, File.basename(job.path))
          FileUtils.mv(job.path, dest, force: true)
          record_history(job, success: false, duration: duration, size_before: size_before, size_after: nil,
                         error: "ffmpeg failed after #{job.attempt + 1} attempt(s)")
          notify_webhook(job, "failure", duration: duration, size_before: size_before, size_after: nil)
        end
      end
    rescue => e
      @logger.error "Error processing #{job.path}: #{e.message}"
      move_to_error(job)
      record_history(job, success: false, duration: nil, size_before: nil, size_after: nil, error: e.message)
      notify_webhook(job, "failure", duration: nil, size_before: nil, size_after: nil, error: e.message)
    ensure
      release(job.path) unless requeued
      @mutex.synchronize { @pid_map.delete(job.path) }
    end

    def release(path)
      @mutex.synchronize { @in_flight.delete(path) }
    end

    # Puts a user-stopped job straight back in the queue. It stays in in_flight so the
    # watcher doesn't enqueue a duplicate.
    def requeue_stopped(job)
      @mutex.synchronize { @pending_jobs << job }
      @queue << job
    end

    # Re-enqueues a job with attempt+1 after a short delay so a transient failure
    # (e.g. a codec hiccup) gets another shot before giving up and moving to error/.
    def requeue_retry(job)
      next_job = job.with(attempt: job.attempt + 1)
      Thread.new do
        sleep @retry_delay
        @mutex.synchronize do
          @in_flight.add(next_job.path)
          @pending_jobs << next_job
        end
        @queue << next_job
      end
    end

    # Re-enqueues a job unchanged after a short delay (used by the disk-space guard).
    def requeue_later(job)
      Thread.new do
        sleep @retry_delay
        @mutex.synchronize do
          @in_flight.add(job.path)
          @pending_jobs << job
        end
        @queue << job
      end
    end

    def record_history(job, success:, duration:, size_before:, size_after:, error: nil)
      return unless @history
      @history.record(
        path:        job.path,
        watch:       File.basename(job.watch_path),
        success:     success,
        finished_at: Time.now.to_i,
        duration:    duration,
        size_before: size_before,
        size_after:  size_after,
        error:       error
      )
    end

    def notify_webhook(job, event, duration:, size_before:, size_after:, error: nil)
      return unless job.webhook_url && job.webhook_events.include?(event)
      Webhook.notify(job.webhook_url, event, {
        path:        job.path,
        watch:       File.basename(job.watch_path),
        duration:    duration,
        size_before: size_before,
        size_after:  size_after,
        error:       error
      }, logger: @logger)
    end

    # Returns a path that does not yet exist: dir/name, dir/name.1.ext, dir/name.2.ext, ...
    def unique_path(dir, filename)
      candidate = File.join(dir, filename)
      return candidate unless File.exist?(candidate)

      base = File.basename(filename, ".*")
      ext  = File.extname(filename)
      n    = 1
      loop do
        candidate = File.join(dir, "#{base}.#{n}#{ext}")
        return candidate unless File.exist?(candidate)
        n += 1
      end
    end

    def save_error_log(job, command, stderr)
      return if (stderr.nil? || stderr.strip.empty?) && command.nil?
      FileUtils.mkdir_p(job.error_dir)
      log_path = File.join(job.error_dir, File.basename(job.path) + ".log")
      contents = +""
      contents << "Command: #{command}\n\n" if command
      contents << (stderr || "")
      File.write(log_path, contents)
    rescue => e
      @logger.warn "Could not save error log: #{e.message}"
    end

    def move_to_error(job)
      FileUtils.mkdir_p(job.error_dir)
      dest = unique_path(job.error_dir, File.basename(job.path))
      FileUtils.mv(job.path, dest, force: true)
    rescue => e
      @logger.error "Could not move to error dir: #{e.message}"
    end
  end
end
