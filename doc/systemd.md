# vaks systemd setup

vaks is designed to run as a systemd **user service** — no root required.

**Why a user service instead of a system service:** vaksd needs to run as the
same user who owns the watched media directories and the ffmpeg processes it
spawns, and it's controlled interactively via `vaksctl` over a per-user Unix
socket (`~/.config/vaks/vaksd.sock` by default). A system service would run
as root (or require a dedicated system user plus permission/socket-path
juggling to let a normal user's `vaksctl` reach it) for no real benefit here.
If you do want vaksd to survive without an active login session, use
`loginctl enable-linger $USER` (below) rather than switching to a system
service.

## Deploying from a git checkout (e.g. /opt/vaks)

If you're running vaks straight from a git clone instead of `gem install vaks`:

```bash
sudo git clone <repo-url> /opt/vaks
cd /opt/vaks
bundle install                      # installs rb-inotify, logger, etc. per Gemfile.lock
```

`bin/vaksd` and `bin/vaksctl` auto-detect the checked-out `Gemfile` and load
gems through Bundler, so you don't need `bundle exec` — just point systemd's
`ExecStart` at `/opt/vaks/bin/vaksd` directly (see below). Make sure the user
running the service can read `/opt/vaks` (a `git clone` as root followed by
`chown -R youruser /opt/vaks`, or cloning directly as that user, both work).

## Install the service unit

```bash
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/vaksd.service << 'EOF'
[Unit]
Description=vaksd video conversion daemon
After=default.target

[Service]
ExecStart=/usr/local/bin/vaksd
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
```

For a git checkout at `/opt/vaks`, use `ExecStart=/opt/vaks/bin/vaksd` instead.

## Using rvm (git checkout)

systemd doesn't load your shell's rvm, so the unit calls rvm itself:
`rvm in /opt/vaks do bundle exec /opt/vaks/bin/vaksd`. rvm picks the ruby and gemset from the
checkout's `.ruby-version` / `.ruby-gemset`, so nothing in the unit names a ruby version.
Install the sample unit [`contrib/vaksd.service`](../contrib/vaksd.service) (edit the `/opt/vaks`
path if your checkout lives elsewhere):

```bash
mkdir -p ~/.config/systemd/user
cp /opt/vaks/contrib/vaksd.service ~/.config/systemd/user/
```

```ini
[Service]
ExecStart=%h/.rvm/bin/rvm in /opt/vaks do bundle exec /opt/vaks/bin/vaksd
```

To change ruby, update `.ruby-version`, then in the checkout run `rvm install <version>` and
`bundle install`, and `systemctl --user restart vaksd`.

For `vaksctl` from any shell, put [`contrib/vaksctl`](../contrib/vaksctl) on your `PATH`
(e.g. `cp /opt/vaks/contrib/vaksctl ~/.local/bin/`); it uses the same command and runs
whichever tool matches its own name, so a `vaksd` symlink to it starts the daemon:

```bash
#!/bin/bash
tool="$(basename "$0")"
exec "$HOME/.rvm/bin/rvm" in /opt/vaks do bundle exec "/opt/vaks/bin/$tool" "$@"
```

```bash
ln -s vaksctl ~/.local/bin/vaksd    # optional, for running the daemon by hand
```

## Enable and start

```bash
systemctl --user daemon-reload
systemctl --user enable --now vaksd
```

## View logs

```bash
journalctl --user -u vaksd -f          # follow live logs
journalctl --user -u vaksd --since today
```

## Stop / restart

```bash
systemctl --user stop vaksd
systemctl --user restart vaksd

# Graceful drain (finish current jobs then stop):
vaksctl drain
```

## Auto-start on login (without requiring active session)

If you want vaks to start even when you are not logged in
(e.g. on a server where you have a persistent user):

```bash
loginctl enable-linger $USER
```

## Checking status

```bash
systemctl --user status vaksd
vaksctl status
```

## Gem installed to a non-default path

If `gem install vaks` puts the binary somewhere that systemd cannot find,
set the full path in the unit:

```ini
[Service]
ExecStart=/home/youruser/.local/share/gem/ruby/4.0.0/bin/vaksd
Environment=HOME=/home/youruser
```

Find the path with: `gem contents vaks | grep bin/vaksd`

## "vaksctl: command not found"

`gem install vaks` (especially `--user-install`, the default for non-root
installs on many distros) puts `vaksctl`/`vaksd` in a per-user gem bin
directory that isn't on `$PATH` by default, e.g.
`~/.local/share/gem/ruby/<version>/bin`. Find it and add it to your shell
profile:

```bash
gem environment gemdir   # e.g. ~/.local/share/gem/ruby/4.0.0
echo 'export PATH="$(ruby -e "puts Gem.user_dir")/bin:$PATH"' >> ~/.bashrc
# (or ~/.zshrc, etc.) then: source ~/.bashrc
```

For a git checkout (e.g. `/opt/vaks`), symlink the binaries onto your PATH
instead of adding the checkout's `bin/` directly (auto-detects the repo's
Gemfile via `BUNDLE_GEMFILE`, so the symlink still works correctly):

```bash
sudo ln -sf /opt/vaks/bin/vaksctl /usr/local/bin/vaksctl
sudo ln -sf /opt/vaks/bin/vaksd   /usr/local/bin/vaksd
```

With rvm, use the wrapper script from [Using rvm](#using-rvm-git-checkout) instead of a
symlink (the symlink's `#!/usr/bin/env ruby` picks whatever ruby is first on `PATH`).

Either way, confirm with `command -v vaksctl` and `vaksctl status` from any
directory.
