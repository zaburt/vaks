require "open3"

module Vaks
  # Background cache of media durations (seconds), probed with ffprobe on a single
  # thread so API requests never block. #get returns the cached value, or nil while
  # the file hasn't been probed yet (or can't be) and schedules a probe if needed.
  class Durations
    MAX_ENTRIES = 5000

    def initialize
      @cache = {}                # path => [mtime, size, seconds|nil]
      @mutex = Mutex.new
      @todo  = Queue.new
      @pending = Set.new
      @thread = Thread.new { probe_loop }
    end

    def get(path)
      stat = File.stat(path) rescue (return nil)
      @mutex.synchronize do
        entry = @cache[path]
        return entry[2] if entry && entry[0] == stat.mtime && entry[1] == stat.size
        @todo << path if @pending.add?(path)
      end
      nil
    end

    private

    def probe_loop
      loop do
        path = @todo.pop
        stat = File.stat(path) rescue nil
        seconds = stat && Ffmpeg.probe_duration(path)
        @mutex.synchronize do
          @pending.delete(path)
          @cache.clear if @cache.size >= MAX_ENTRIES
          @cache[path] = [stat.mtime, stat.size, seconds] if stat
        end
      end
    rescue => e
      warn "vaks: duration probe thread crashed: #{e.message}"
    end
  end
end
