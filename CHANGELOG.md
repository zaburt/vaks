# Changelog

## [Unreleased]

### Added
- Remote mode for `vaksctl` — `-r/--remote NAME|URL`, `--token`, `--local`, `VAKS_REMOTE`/`VAKS_URL`/`VAKS_TOKEN` and `~/.config/vaks/remotes.yml` (with a `default:` remote) let every command drive a vaksd on another machine over the HTTP API
- `vaksctl wait [--timeout S]` (blocks until idle; exit 0 done, 1 a job failed, 2 timeout), global `--json` output, and `vaksctl status --all` across every remote in `remotes.yml`
- Watch management over HTTP — `POST /api/watch-add`, `/api/watch-update`, `/api/watch-remove` and `GET /api/config`; `vaksctl watch update PATH [options]`; optional `allowed_roots` in `config.yml` restricts which directories remote clients may watch

- Sample `contrib/vaksd.service` and `contrib/vaksctl` that use `rvm in /opt/vaks do bundle exec ...`, so the ruby/gemset come from `.ruby-version`/`.ruby-gemset` with no hard-coded ruby version

### Fixed
- `vaksctl watch add --extra-args` was parsed but never written to the watch config

## [1.0.0] - 2026-10-18

### Security
- The HTTP API now binds to `127.0.0.1` by default and refuses to listen on any other address without `http_token`.
- `POST /api/config` no longer accepts `idle_shutdown_command` (it executes a shell command); set it in `config.yml`.
- Dropped the wildcard CORS headers, compare the token in constant time, and reject `..` in `/api/retry-job` paths.

### Added
- Test suite (`bundle exec rake test`) covering the priority queue, stop/pause/power control and HTTP auth.
- Plasma widget: full-colour video-frame tray icon with a real progress bar and large job counts.
- Immediate stop — `stop-job` (CLI/socket/HTTP/widget) now SIGKILLs ffmpeg and holds the queue so no other file starts; `vaksctl resume` / `POST /api/resume` / the widget's **Start** restarts encoding. Stopped files go back to the queue and restart from scratch instead of being moved to `error/`
- Time-remaining estimates — the daemon probes media durations (ffprobe, cached, in the background) and `/api/status` / `/api/queue` include `duration`; the Plasma widget shows time left per running job, an estimate per queued file, and a total remaining for the source (remaining media time ÷ current encode speed, spread over the workers)
- Pause/continue — `vaksctl pause`/`unpause`, `POST /api/pause`/`/api/unpause` and the widget's **Pause**/**Continue** freeze ffmpeg with SIGSTOP and thaw it with SIGCONT, so encoding continues from the same frame without restarting; the queue is held while paused and a daemon drain thaws frozen jobs
- After-process power action — `vaksctl power`, `POST /api/power` and a widget selector (`none`, shutdown/reboot after current job(s) or after everything), changeable at runtime and executed via systemd-logind over D-Bus (new `ruby-dbus` dependency)
- If a queued file is moved out of (or deleted from) its watched directory before a worker picks it up, its pending job is now removed from the queue instead of lingering until a worker skips it — this also prevents duplicate processing when a file is moved between two watched directories
- Automatic retry-on-failure: watches (and the global default) can set `retries`/`retry_delay`; a failed job is re-queued with a delay instead of moving straight to `error/`, up to the configured attempt count
- Disk-space guard — `min_free_space_mb` (global or per-watch) defers encoding (re-checked later) instead of starting a job when free space on the target filesystem is too low
- Webhook notifications — `webhook_url`/`webhook_events` (global or per-watch) POST a JSON payload on job success/failure, delivered asynchronously so a slow/unreachable endpoint never blocks encoding
- Small-file priority boost — `small_file_bytes`/`small_file_priority_boost` bump the queue priority of files at or under a size threshold so small/quick jobs jump ahead of large ones
- Named profile presets — a top-level `profiles:` map in `config.yml` lets watches select a preset by name (`profile_preset:`) instead of repeating ffmpeg args/output settings, with per-watch overrides layered on top
- Job history — the daemon keeps a ring buffer of recent completed/failed jobs (size, duration, space saved); available via `GET /api/history`, `vaksctl history`, and the socket `history` command, and now feeds the Plasma widget's stats view
- Retry a specific failed job on demand via `POST /api/retry-job`, `vaksctl retry-job PATH`, or the socket `retry-job` command
- HTTP API rate-limiting and audit log — repeated failed auth attempts from an IP are temporarily blocked (429), and every HTTP request is appended to `log_dir/http_audit.log`
- Per-watch/global `nice`/`ionice_class`/`ionice_level` throttle the ffmpeg process's CPU/IO priority without affecting `stop-job`/kill-by-PID behavior
- Plasma widget: a failed-job count badge on the compact tray icon, a "History & stats" overlay with aggregate and per-source breakdowns, "Open folder"/"Retry" action buttons on job notifications, a theme-adaptive symbolic tray icon, and more resilient SSE reconnect (keeps retrying in the background instead of getting stuck on polling)

## [0.7.0] - 2026-07-14

### Added
- ffmpeg is now always invoked with `-y` (force overwrite), fixing a latent bug where a stale output file left in `working_dir` by a crashed/killed previous run would cause ffmpeg to abort immediately (it can't prompt with `-nostdin`)
- On daemon startup, each watch's `working_dir` is swept and any leftover files from a previous run are removed (never during hot-reload, so in-progress job output is untouched)
- Realtime job output — the daemon now buffers the last 200 lines of raw ffmpeg stderr per running job; fetch it via `GET /api/job-output?path=...`, `vaksctl job-output PATH [--follow]`, or the new socket `job-output` command
- Plasma widget: an "Output" toggle button on each running job opens a scrollable, auto-refreshing panel showing live ffmpeg output

### Fixed
- `bin/vaksd`/`bin/vaksctl` now auto-load gems via Bundler when a `Gemfile` is present next to them (e.g. a git checkout deployed to `/opt/vaks`), so `bundle install` + a plain `ExecStart=/opt/vaks/bin/vaksd` is enough — no `bundle exec` required. Gem-installed deployments (no bundled `Gemfile`) are unaffected.
- Added explicit `logger` gem dependency — Ruby 4.0 no longer bundles it by default, and Bundler-based deployments would fail to boot without it
- Fixed a crash on `SIGTERM`/`SIGINT` (e.g. `systemctl stop`/`restart`): the drain logic used a mutex and joined threads directly inside the signal trap, which Ruby forbids ("can't be called from trap context"). Draining is now deferred to a background thread so graceful shutdown works reliably.

## [0.6.0] - 2026-07-14

### Added
- `startup_delay` config option — daemon waits N seconds after starting before encoding begins
- Watch suspend/resume — `enabled: false` in a watch yml (or `vaksctl watch suspend/resume`, `/api/watch-toggle`) stops it from enqueuing new files without removing the watch; hot-reloaded like any other config change
- Queue reordering — `vaksctl queue reorder PATH...` and `POST /api/queue-reorder` let you manually reprioritize pending jobs
- Worker count can now be changed remotely over the HTTP API (`POST /api/config {"workers": N}`) and `vaksctl config set-workers N`, not just from the daemon's own config file
- Plasma widget: queue reorder panel, per-watch suspend/resume switches (suspended watches sort to the bottom), and a worker-count control in the config panel
- ffmpeg error logs (`error/*.log`) now include the full ffmpeg command line, not just stderr

### Removed
- MQTT support removed entirely (daemon-side client, config options `mqtt_host`/`mqtt_port`/`mqtt_id`/`mqtt_username`/`mqtt_password`, and the `mqtt` gem dependency) — the HTTP API and `vaksctl` cover the same control surface

## [0.5.0] - 2026-06-27

### Changed
- Plasma widget transport replaced: MQTT removed, HTTP polling via `HttpSource.qml`
- `install.sh` rewritten — no longer requires QtMqtt or Mosquitto setup
- README updated to reflect HTTP-first architecture

## [0.4.0] - 2026-06-27

### Added
- HTTP JSON API server (`http_port`, `http_host`, `http_token` in config.yml) — endpoints for status, queue, watches, drain, flush, stop-job, config
- Plasma 6 widget rewritten to use HTTP polling instead of MQTT (`HttpSource.qml`)
- Priority queue — `watch add --priority N`; higher priority jobs processed first; `in/movs` gets priority -5
- Dynamic worker count — changing `workers` via MQTT or HTTP `/api/config` takes effect immediately
- Queue contents — `vaksctl queue` now lists pending files, not just a count
- `watch list` shows full profile, dirs, delay, priority, and custom flag per watch
- `--working-dir` for `watch add` — encode to temp dir, move to done/ on success
- `--source-done-dir` for `watch add` — move original source file after successful encode
- `--custom` for `watch add` — requires a `.vaks.yml` sidecar file alongside media to trigger encoding
- File collision handling — unique filenames (`file.1.mkv`, `file.2.mkv`) instead of silent overwrites
- ffmpeg stderr saved as `filename.mkv.log` in `error/` on encoding failure
- Daemon log to file — `log_dir` in config.yml writes to `log_dir/vaks.log` alongside stdout
- Binary renamed from `vaks` to `vaksd`; systemd unit renamed to `vaksd.service`

## [0.3.0] - 2026-06-27

### Added
- `--working-dir` option for `vaksctl watch add`: encode to a temp directory and move to `done/` on success, keeping `done/` free of partial files
- `--source-done-dir` option for `vaksctl watch add`: move original source file to a dedicated directory after successful encode instead of leaving it in the watch path

## [0.1.0] - 2026-06-19

### Added
- Initial release
- Daemon with inotify-based directory watching (`rb-inotify`)
- Per-directory conversion profiles (yaml)
- Worker thread pool with configurable concurrency
- ffmpeg integration via Open3 with real-time progress parsing
- Unix socket control interface
- `vaksctl` CLI: status, queue, stop-job, flush-queue, drain, watch management
- Systemd user service support
- Error handling: failed jobs moved to `error/` subdirectory
- Hot-reload of watch configs via inotify on `watches/` directory
