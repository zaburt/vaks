module Vaks
  # Immutable value object representing a single conversion job.
  # The profile is snapshotted at enqueue time so config changes mid-run have no effect.
  # `attempt` starts at 0 and is bumped by the retry policy on failure (see Worker);
  # `retries` is the max number of retries allowed before the job is moved to error/.
  Job = Data.define(:path, :profile, :done_dir, :working_dir, :source_done_dir, :error_dir,
                    :watch_path, :delay, :priority, :retries, :attempt,
                    :min_free_space_mb, :webhook_url, :webhook_events,
                    :nice, :ionice_class, :ionice_level) do
    def initialize(retries: 0, attempt: 0, min_free_space_mb: nil, webhook_url: nil,
                   webhook_events: %w[success failure], nice: nil, ionice_class: nil,
                   ionice_level: nil, **rest)
      super(retries: retries, attempt: attempt, min_free_space_mb: min_free_space_mb,
            webhook_url: webhook_url, webhook_events: webhook_events, nice: nice,
            ionice_class: ionice_class, ionice_level: ionice_level, **rest)
    end
  end
end
