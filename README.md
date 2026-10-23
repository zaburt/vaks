# vaks

A Ruby daemon that watches directories for video files and converts them
with ffmpeg according to per-directory profiles. Managed by systemd,
controlled at runtime by the `vaksctl` CLI, and monitored from a Plasma 6
system-tray widget over HTTP.

## Features

- Watches multiple directories simultaneously via inotify
- Per-directory conversion profiles (video codec, audio codec, resolution, extra ffmpeg args)
- Priority queue — higher-priority watches are processed first, and the pending queue can be manually reordered at runtime
- Worker thread pool with configurable concurrency (adjustable at runtime, including from the Plasma widget)
- Optional startup delay — wait before the daemon begins encoding after it first starts
- `working/` staging directory — encoded files land in `done/` only when complete
- `source_done/` directory — original source files moved here after successful encode
- Custom watches — require a `.vaks.yml` sidecar file per media file to trigger encoding
- Suspend/resume individual watches temporarily without removing them
- Hot-reload of watch configs — add, remove, or suspend a `.yml` file without restarting
- On ffmpeg failure: source moved to `error/`, ffmpeg command and output saved as `filename.mkv.log`
- File collision handling — `file.1.mkv`, `file.2.mkv` instead of silent overwrites
- HTTP JSON API for remote monitoring and control (used by the Plasma widget), with rate-limited auth and an audit log
- Automatic retry-on-failure with configurable delay/attempt count
- Disk-space guard — defer encoding when free space is too low
- Webhook notifications on job success/failure
- Small-file priority boost — small files jump ahead of large ones in the queue
- Named profile presets, selectable per watch
- Job history (size/duration/space-saved) with a stats API and Plasma widget view
- Per-watch/global `nice`/`ionice` throttling of the ffmpeg process
- Systemd user service — no root required
- Logs to stdout → journald; optionally also to a file via `log_dir`

## Requirements

- Ruby >= 4.0.0
- ffmpeg on `$PATH`
- Linux (inotify)

## Installation

```bash
gem install vaks
```

If `vaksctl` (or `vaksd`) isn't found after installing, the gem's bin
directory isn't on your `$PATH` — see
["vaksctl: command not found"](doc/systemd.md#vaksctl-command-not-found)
in doc/systemd.md.

See [doc/systemd.md](doc/systemd.md) for service setup.

## Configuration

All config lives under `~/.config/vaks/`.

### `~/.config/vaks/config.yml`

```yaml
workers: 2                   # number of concurrent ffmpeg processes
log_level: info              # debug | info | warn | error
log_dir: ~                   # write vaks.log here in addition to stdout (nil = disabled)
idle_shutdown: false         # exit automatically when idle
idle_shutdown_timeout: 30    # seconds of idle before shutdown
idle_shutdown_command: ~     # shell command run after idle shutdown drains (e.g. "systemctl poweroff"); nil = just stop the daemon
startup_delay: 0             # seconds to wait after daemon start before encoding begins
http_port: 6283              # HTTP API port (nil = disabled)
http_host: 127.0.0.1         # bind address for HTTP API (loopback by default; see "Security")
http_token: ~                # bearer token for the HTTP API — required when http_host is not loopback
done_dir: ~                  # default done dir for all watches (nil = relative "done/" inside watch path)
working_dir: ~               # default working dir for all watches (nil = encode directly into done_dir)
source_done_dir: ~           # default source_done dir for all watches (nil = delete source after encode)
error_dir: ~                 # default error dir for all watches (nil = relative "error/" inside watch path)
extensions:                  # file extensions to process
  - mkv
  - mp4
  - avi
  - mov
  - ts
  - m4v
  - webm
default_profile:             # baseline profile — watch profiles override per key
  codec_video: libx265
  codec_audio: aac
  codec_subtitle: copy
  smart_audio: true
default_retries: 0            # default retry attempts on ffmpeg failure before moving to error/
retry_delay: 30                # seconds to wait before re-queuing a failed job
min_free_space_mb: ~           # defer encoding if free space on the target filesystem drops below this (nil = disabled)
webhook_url: ~                 # POST a JSON payload here on job success/failure (nil = disabled)
webhook_events: [success, failure]  # which events to send to webhook_url
small_file_bytes: ~            # files at/under this size get a priority boost (nil = disabled)
small_file_priority_boost: 0    # amount added to priority for small files
http_rate_limit_max: 5          # failed auth attempts allowed before an IP is blocked
http_rate_limit_window: 60      # seconds over which failed attempts are counted
http_rate_limit_block: 300      # seconds an IP stays blocked after exceeding the limit
allowed_roots: []               # remote watch add/update only accept paths inside these directories (empty = any existing directory)
profiles:                       # named presets — reference by name via a watch's `profile_preset:`
  hq:
    codec_video: libx265
    codec_audio: aac
    extra_args: "-crf 20 -preset slow"
  fast:
    codec_video: libx264
    codec_audio: copy
    extra_args: "-crf 28 -preset veryfast"
```

### `~/.config/vaks/watches/*.yml`

Each file defines one watched directory. The daemon picks up changes automatically via inotify — no restart needed.

```yaml
path: /media/convert/in/default
done_dir: /media/convert/done
working_dir: /media/convert/working       # temp dir while encoding; moved to done/ on success
source_done_dir: /media/convert/source_done  # original moved here after success
error_dir: /media/convert/error
delay: 0           # seconds to wait before starting each encode
priority: 0        # higher = processed before lower-priority watches
custom: false      # if true: only encode when a .vaks.yml sidecar file is present
enabled: true       # false = suspended — watch stays configured but stops enqueuing new files
profile_preset: ~   # name of a preset from config.yml's `profiles:` map (nil = none)
retries: ~           # per-watch override of default_retries
min_free_space_mb: ~ # per-watch override of the global disk-space guard
webhook_url: ~       # per-watch override of the global webhook_url
webhook_events: ~    # per-watch override of the global webhook_events
nice: ~              # nice(1) priority for the ffmpeg process (e.g. 10; nil = unset)
ionice_class: ~      # ionice(1) scheduling class (1=realtime, 2=best-effort, 3=idle; nil = unset)
ionice_level: ~      # ionice(1) priority within the class (0-7; nil = unset)
profile:
  codec_video: libx265
  codec_audio: aac
  codec_subtitle: copy
  resolution: 1280x720         # optional — maps to ffmpeg -s
  smart_audio: true            # skip re-encode if audio codec already matches
  extra_args: "-crf 23 -preset slow"   # optional — appended verbatim to ffmpeg args
```

`done_dir`, `working_dir`, `source_done_dir`, and `error_dir` are relative to `path` unless they start with `/`.

### Custom watches

For a watch with `custom: true`, vaks will not auto-encode files. Instead, drop a sidecar
file named `<filename>.vaks.yml` alongside the media file to trigger encoding:

```yaml
# /media/convert/in/custom/movie.mkv.vaks.yml
codec_video: libx264
codec_audio: copy
resolution: 1280x720
```

The sidecar profile is merged over the watch's default profile.

## Directory layout (recommended)

```
/media/convert/
  in/
    default/       ← default profile
    aac/           ← explicit AAC audio
    smol/          ← libx264, copy audio
    movs/          ← priority -5 (processed last)
    custom/        ← sidecar .vaks.yml required
    1280x720/      ← resolution override
  working/         ← staging during encode
  done/            ← finished encoded files
  source_done/     ← originals after successful encode
  error/           ← failed sources + .log files
  log/             ← daemon log
```

## vaksctl

```
vaksctl status                          show running jobs, queue depth, watch count
vaksctl queue                           list pending jobs in processing order
vaksctl queue reorder PATH...           reorder the queue (first PATH is processed first)
vaksctl stop-job /path/to/file.mkv      SIGKILL a specific ffmpeg job immediately and hold the queue
vaksctl stop-job --all                  SIGKILL all running ffmpeg jobs immediately and hold the queue
vaksctl pause [--all|PATH]              freeze ffmpeg in place (SIGSTOP) and hold the queue — no progress is lost
vaksctl unpause                         continue frozen jobs exactly where they left off (SIGCONT)
vaksctl resume                          start encoding again (stopped files restart from scratch, never moved to error/)
vaksctl power shutdown-after-all        what to do when finished; also: reboot-after-all,
                                        shutdown-after-current, reboot-after-current, none (cancels)
vaksctl flush-queue                     clear pending queue (running jobs finish)
vaksctl drain                           finish current jobs then stop daemon
vaksctl config set-workers N            change worker count on the running daemon

vaksctl watch list
vaksctl watch add /media/convert/in/aac \
  --codec-audio aac \
  --done-dir /media/convert/done \
  --working-dir /media/convert/working \
  --source-done-dir /media/convert/source_done \
  --error-dir /media/convert/error
vaksctl watch remove /media/convert/in/aac
vaksctl watch suspend /media/convert/in/aac   # stop enqueuing new files temporarily
vaksctl watch resume /media/convert/in/aac
vaksctl job-output /media/convert/in/aac/movie.mkv           # show buffered ffmpeg output
vaksctl job-output /media/convert/in/aac/movie.mkv --follow  # keep polling for new output
vaksctl history                          show job history stats and recent events
vaksctl retry-job /media/convert/error/movie.mkv   re-queue a failed job for another attempt
```

`watch add` options:

| Option | Description |
|---|---|
| `--codec-video V` | Video codec (e.g. `libx265`, `libx264`, `copy`) |
| `--codec-audio V` | Audio codec (e.g. `aac`, `copy`) |
| `--codec-subtitle V` | Subtitle codec (e.g. `copy`) |
| `--resolution V` | Output resolution (e.g. `1280x720`) |
| `--extra-args V` | Extra ffmpeg arguments (quoted string) |
| `--smart-audio` | Skip audio re-encode if codec already matches |
| `--done-dir V` | Output directory (default: `done/` inside watch path) |
| `--working-dir V` | Temp dir during encode; moved to `done/` on success |
| `--source-done-dir V` | Move source here after successful encode |
| `--error-dir V` | Error directory (default: `error/` inside watch path) |
| `--delay N` | Seconds to wait before encoding each file (default: 0) |
| `--priority N` | Job priority; higher = processed first (default: 0) |
| `--custom` | Require a `.vaks.yml` sidecar file to trigger encoding |
| `--profile-preset V` | Use a named preset from `config.yml`'s `profiles:` map |
| `--retries N` | Retry attempts on ffmpeg failure before moving to `error/` |
| `--min-free-space-mb N` | Defer encoding while free space on the target filesystem is below this |
| `--webhook-url V` | POST a JSON payload here on job success/failure |
| `--webhook-events V` | Comma-separated events to send (`success`, `failure`) |
| `--nice N` | `nice(1)` priority for the ffmpeg process |
| `--ionice-class N` | `ionice(1)` scheduling class (1=realtime, 2=best-effort, 3=idle) |
| `--ionice-level N` | `ionice(1)` priority within the class (0-7) |

## Remote control

`vaksctl` can drive a vaksd on another machine over its HTTP API (set `http_host`, `http_port`
and `http_token` there). Every command works the same; paths are then paths on the remote
machine and must be absolute.

```bash
vaksctl -r desk status
vaksctl -r http://desk:6283 --token SECRET queue
vaksctl -r desk watch add /media/inbox --codec-video libx265
vaksctl --local status        # ignore any configured remote
```

`vaksctl status --all` shows every remote listed in `remotes.yml` (unreachable ones are reported,
not fatal). `--json` (works in local mode too) prints the daemon's response as JSON and exits 1
on error. `vaksctl wait [--timeout S]` blocks until nothing is running or queued — exit 0 when
done, 1 if a job failed in the meantime, 2 on timeout — handy in scripts:
`vaksctl wait && notify-send "encoding finished"`.

Settings are resolved in this order: flags (`-r/--remote`, `--token`, `--local`) → environment
(`VAKS_REMOTE`, `VAKS_URL`, `VAKS_TOKEN`) → `~/.config/vaks/remotes.yml` → local unix socket.
A bare host defaults to port 6283.

```yaml
# ~/.config/vaks/remotes.yml   (chmod 600 — it holds tokens)
default: desk                 # used when no flag/env is given
remotes:
  desk:
    url: http://desk:6283
    token: SECRET
```

Remote watch changes are validated by the daemon: paths must be absolute, free of `..`, an
existing directory, and — when `allowed_roots` is set in the daemon's `config.yml` — inside one
of those directories. The API is plain HTTP, so use it on a trusted network or behind a tunnel.

## vakstui

`vakstui` is a full-screen console UI with the same features as the Plasma widget. It needs nothing
beyond Ruby (plain ANSI, no extra gems) and takes the same connection options as `vaksctl`
(`-r/--remote`, `--token`, `--local`, `VAKS_REMOTE`/`VAKS_URL`/`VAKS_TOKEN`, `remotes.yml`).

```
vakstui                  # local daemon, or the default remote from remotes.yml
vakstui -r desk          # a named remote
```

| Key | Action |
|---|---|
| `Tab` / `Shift+Tab` | Move focus between Running, Queue and the bottom pane |
| `j` `k` / arrows, `PgUp` `PgDn` | Move the selection |
| `1` `2` `3` | Bottom pane: History / Watches / Output |
| `Enter` | On a running job: show its live ffmpeg output |
| `p` | Pause / continue all running jobs |
| `s` / `S` | Stop the selected job / all jobs |
| `r` | Resume the queue after a stop |
| `x` / `d` | Flush the queue / drain the daemon (both ask first) |
| `J` / `K` | Move the selected queued job down / up |
| `t` | Retry the selected failed job (History) |
| `n` `e` `D` `Space` | Watches: new, edit, remove, suspend/resume |
| `+` / `-` | Add / remove a worker |
| `a` | When finished: shut down / reboot after the current job or after everything |
| `m` | Mute desktop notifications (this session only) |
| `[` / `]` | Previous / next daemon from `remotes.yml` |
| `?` / `q` | Help / quit |

Job completions and failures raise a desktop notification through `notify-send` when it is
installed. The watch form sends only the fields you changed; clearing a field removes it from the
watch so the global default applies again.

## HTTP API

When `http_port` is set in `config.yml`, vaksd exposes a JSON API:

| Method | Path | Description |
|---|---|---|
| GET | `/api/job-output?path=...` | Last buffered ffmpeg stderr lines (up to 200) for a running job |
| GET | `/api/history` | Job history: recent events plus aggregate stats (total, succeeded, failed, space saved, avg duration) |
| GET | `/api/events` | Server-Sent Events stream — pushes a combined `{status, queue, watches, history}` snapshot roughly every second, so clients don't need to poll |
| POST | `/api/queue-reorder` | `{"paths":["/a.mkv","/b.mkv"]}` — first path processed first |
| POST | `/api/drain` | Graceful stop |
| POST | `/api/flush-queue` | Clear pending queue |
| POST | `/api/stop-job` | `{"all":true}` or `{"path":"..."}` — SIGKILL ffmpeg immediately and hold the queue; killed jobs go back to the queue |
| POST | `/api/pause` | `{"all":true}` or `{"path":"..."}` — SIGSTOP ffmpeg (frozen, keeps RAM/partial output) and hold the queue; jobs report `"paused":true` |
| POST | `/api/unpause` | SIGCONT frozen jobs, continuing from the same frame, and release the queue |
| POST | `/api/resume` | Release the hold set by `stop-job`; stopped files restart from scratch |
| POST | `/api/power` | `{"action":"shutdown_after_all"}` — one of `none`, `shutdown_after_all`, `reboot_after_all`, `shutdown_after_current`, `reboot_after_current`; switchable at any time, `none` cancels |
| POST | `/api/retry-job` | `{"path":"..."}` — re-queue a job currently in `error/` for another attempt |
| POST | `/api/watch-toggle` | `{"path":"...","enabled":false}` — suspend/resume a watch |
| GET | `/api/config` | Non-secret daemon settings (workers, idle shutdown, `allowed_roots`, …) |
| POST | `/api/watch-add` | `{"path":"/media/in","priority":2,"profile":{"codec_video":"libx265"}}` — create a watch; accepts the same fields as a watch yml |
| POST | `/api/watch-update` | `{"path":"...","priority":5,"profile":{"codec_audio":null}}` — change only the given fields; `null` removes a field / profile key |
| POST | `/api/watch-remove` | `{"path":"..."}` — delete a watch |
| POST | `/api/config` | Update `workers` / `idle_shutdown` / `idle_shutdown_timeout` / `idle_shutdown_command` |

If `http_token` is set, include `Authorization: Bearer <token>` in every request. Repeated failed
auth attempts from an IP are rate-limited (429 after `http_rate_limit_max` failures within
`http_rate_limit_window` seconds, blocked for `http_rate_limit_block` seconds); every request is
also appended to `log_dir/http_audit.log` when `log_dir` is set.

```bash
curl http://desk:6283/api/status
```

## Plasma 6 widget

The `plasma-vaks/` directory contains a Plasma 6 system-tray widget that connects to the
HTTP API (via a live SSE stream, falling back to polling if unavailable) and lets you monitor and control vaksd from your KDE desktop.

### After-process power actions

`vaksctl power` / `POST /api/power` / the widget's **When finished** selector choose what happens to the
machine. Switch it at any time; `none` cancels a pending action.

| Action | When it fires |
|---|---|
| `shutdown_after_all` / `reboot_after_all` | Queue empty and nothing encoding for 10s |
| `shutdown_after_current` / `reboot_after_current` | Running jobs finish; no new job starts (queue is kept) |

The call goes to systemd-logind over the system D-Bus (`org.freedesktop.login1`, via the `ruby-dbus` gem) —
no shell commands. polkit must allow the vaksd user to power off/reboot (normally true for an active local
session). The selected action is runtime-only and resets to `none` when the daemon restarts; failures show
as `power_error` in the status and in the widget.

### What the widget does

- Video-frame tray icon in full colour (a progress bar underneath fills with the real encode progress; grey with pause bars when on hold) with the active/queued job count beside it, plus a red failed-job count
- Popup showing each source: connection status, running jobs (filename / elapsed / fps / speed), queue depth, watch count
- Per-source buttons: **Drain**, **Flush**, **Pause** (freezes ffmpeg, **Continue** picks up where it left off), **Stop** (kills ffmpeg instantly, holds the queue) / **Start** (resumes), and a **When finished** selector (do nothing / shut down or reboot after current job(s) / after everything)
- Queue panel: reorder pending jobs with up/down controls, or jump a job straight to the front with the prioritize button — applied live
- Watches panel: suspend/resume individual watches with a switch; suspended watches sort to the bottom
- Suspend notifications temporarily from the widget toolbar — vaksd keeps encoding, only the widget's notifications pause (not persisted, resets on restart)
- Time remaining: per running job, per queued file, and a total per source (estimated from ffprobe durations and the current ffmpeg speed)
- Per running job: an **Output** toggle opens a scrollable, auto-refreshing panel with live ffmpeg output
- **History & stats** overlay: aggregate and per-source job counts, failures, space saved, and average duration
- Expandable config panel: change worker count, toggle idle shutdown, and set the timeout — applied live without restart
- Desktop notifications when jobs complete or fail, with **Open folder**/**Retry** action buttons
- Resilient SSE connection — automatically keeps retrying a live push connection in the background instead of getting stuck on polling

### Installation

**On the machine running vaksd**, enable the HTTP API in `~/.config/vaks/config.yml`:

```yaml
http_port: 6283
# http_token: yourtoken   # recommended on untrusted networks
```

Then restart vaksd:

```bash
systemctl --user restart vaksd
```

**On your Plasma desktop:**

```bash
cd plasma-vaks
./install.sh
```

Right-click your panel → **Add Widgets** → search for **vaks**.

Open widget settings and add a source:

| Field | Value |
|---|---|
| Name | desk |
| Host | `<hostname or IP of the machine running vaksd>` |
| HTTP port | 6283 |
| Token | your token (if `http_token` is set) |

## Security

The HTTP API can pause or kill encodes and power the machine off, so treat it like a remote control.

- `http_host` defaults to `127.0.0.1`. To monitor from another machine (e.g. the Plasma widget) set
  `http_host: 0.0.0.0` **and** an `http_token`; vaksd refuses to expose the API off loopback without a token
  and logs `HTTP API disabled`.
- The API speaks plain HTTP, so the token is visible on the wire. Use a trusted LAN, or tunnel it
  (`ssh -L 6283:localhost:6283 host`, WireGuard, a TLS reverse proxy).
- `idle_shutdown_command` runs a shell command and can only be set in `config.yml` (or over the local Unix
  socket) — `POST /api/config` ignores it.
- No CORS headers are sent, so web pages cannot drive the API from a browser.

## Development

```bash
bundle install
bundle exec rake test
```


## Debugging the socket directly

```bash
echo '{"cmd":"status"}' | socat - UNIX-CONNECT:~/.config/vaks/control.sock
```

## How it works

1. On startup, vaksd optionally waits `startup_delay` seconds; it also sweeps each watch's `working_dir` for leftover files from a previous crashed/killed run before registering any watches, then reads all `watches/*.yml` files and registers inotify watchers
2. It also watches `watches/` itself — adding, deleting, or editing a `.yml` file (including toggling `enabled`) hot-reloads the watch list
3. For each newly registered watch, the inotify watcher is started first, then existing files are scanned (skipped for suspended watches) — no file is missed during startup
4. Matching files are pushed onto a priority queue with a snapshotted profile (config changes mid-run do not affect queued or running jobs); the pending order can be changed manually at runtime
5. Worker threads pop jobs from the queue in priority order, optionally wait for `delay` seconds, then run ffmpeg (always with `-y` to force-overwrite any leftover output) via `Open3` and parse progress from stderr in real time; the last 200 lines of raw stderr per running job are buffered and available via `/api/job-output`
6. On success: encoded file moves from `working/` to `done/`; source file moves to `source_done/` (if configured)
7. On failure: partial output cleaned up, source moved to `error/`, the full ffmpeg command and stderr saved as `source.mkv.log`

## License

Copyright (c) 2026 Onur Küçük (onur [at] delipenguen.net) Licensed under [GNU GPLv2](LICENSE)
