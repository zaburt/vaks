module Vaks
  # Thread-safe, bounded ring buffer of recently completed/failed jobs, used
  # by the /api/history endpoint and the Plasma widget's stats view.
  class History
    DEFAULT_LIMIT = 200

    def initialize(limit: DEFAULT_LIMIT)
      @limit  = limit
      @mutex  = Mutex.new
      @events = []
    end

    # record: { path:, watch:, success:, started_at:, finished_at:, duration:,
    #           size_before:, size_after:, error: }
    def record(entry)
      @mutex.synchronize do
        @events.unshift(entry)
        @events.pop while @events.length > @limit
      end
    end

    def to_a
      @mutex.synchronize { @events.dup }
    end

    # Aggregate stats: total processed, failed count, total space saved (bytes),
    # and average encode speed multiplier (ffmpeg "speed=" reported by the last job
    # that had one available isn't meaningful in aggregate, so we report avg duration/size ratio).
    def stats
      @mutex.synchronize do
        total   = @events.length
        failed  = @events.count { |e| !e[:success] }
        saved   = @events.sum { |e| ((e[:size_before] || 0) - (e[:size_after] || 0)) }
        saved   = 0 if saved.negative? && total.zero?
        durations = @events.filter_map { |e| e[:duration] }
        avg_duration = durations.empty? ? 0 : (durations.sum / durations.length.to_f)
        {
          total:          total,
          succeeded:      total - failed,
          failed:         failed,
          space_saved:    saved,
          avg_duration:   avg_duration
        }
      end
    end
  end
end
