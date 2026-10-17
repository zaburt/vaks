require "open3"

module Vaks
  # Disk-space guard: checks free space on the filesystem holding a given
  # directory, using `df` (no extra gem dependency; Linux-only like the rest
  # of vaks, which already relies on inotify).
  module DiskSpace
    # Returns free space in megabytes for the filesystem containing `dir`,
    # or nil if it can't be determined (missing dir, `df` not on PATH, etc.)
    def self.free_mb(dir)
      return nil unless dir && Dir.exist?(dir)
      out, status = Open3.capture2("df", "-Pk", "--", dir)
      return nil unless status.success?

      line = out.lines[1]
      return nil unless line
      available_kb = line.split[3].to_i
      available_kb / 1024
    rescue Errno::ENOENT
      nil
    end

    # Returns true if the filesystem holding `dir` has less than `min_mb` free.
    # Always returns false if either argument is nil or space can't be determined
    # (fail open — never blocks encoding just because we couldn't check).
    def self.low?(dir, min_mb)
      return false unless dir && min_mb
      free = free_mb(dir)
      return false if free.nil?
      free < min_mb
    end
  end
end
