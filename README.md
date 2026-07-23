# Vai

`vai` runs project commands and manages background jobs through a persistent daemon.

## Tasks and environment

Tasks are loaded from `vai.toml`, global config, and matching presets. A project `.env` file is loaded after the parent environment and overrides matching values for both foreground and background commands.

```toml
[tasks.up]
description = "Start the application"
command = 'docker compose -p ${PROJECT:-$CWD} up -d'
```

Run a configured task in the foreground:

```sh
vai up
```

## Background jobs

```sh
vai -b pnpm dev
vai --bg pnpm dev
vai -b --persistent pnpm dev
```

The CLI returns after the daemon starts the job. Each job runs in its own process group and writes combined stdout/stderr to its log file.

List jobs (the default list target) or sessions:

```sh
vai -l
vai --list jobs
vai --list sessions
```

Inspect or follow output:

```sh
vai -o j1          # one job
vai -o             # all jobs in the current session
vai -o -f          # all current-session output, then follow
vai -o j1 -f       # one job, then follow
```

Combined session output uses colored job headers to identify its source. Background jobs receive `FORCE_COLOR=1` and `CLICOLOR_FORCE=1`; output replay preserves stored ANSI colors. Programs that ignore these variables may still require their own `--color=always` option.

Remove jobs or sessions from daemon state:

```sh
vai --rm j1
vai --rm s1
```

Removing a running object first sends `SIGTERM` to its process group. The daemon follows with `SIGKILL` after the stop timeout if it is still running. Removing a job deletes its log; removing a session deletes every job log associated with that session. Normally exited jobs retain their logs until removed.

Toggle a session between ephemeral and persistent mode:

```sh
vai --mode <session>
```

The command prints the resulting mode. Switching to ephemeral mode attaches the watcher to the current TTY.

## Session lifetime

Sessions are grouped by controlling TTY.

- **Ephemeral** is the default. A daemon-owned watcher thread monitors the originating TTY. When it closes, the daemon terminates every job process group in that session and removes the session.
- **Persistent** sessions survive terminal closure. `--persistent` upgrades the current session and does not get implicitly downgraded by later jobs.

The watcher only monitors terminal lifetime; it never owns jobs.

## Runtime data

The CLI starts the daemon automatically. It can also be started explicitly; the command daemonizes itself and immediately returns the shell prompt:

```sh
vai --daemon
# or: vai -d
```

The daemon uses a Unix-domain socket and keeps registry state in memory. Logs remain on disk, but daemon restart recovery is not currently implemented.

Path overrides useful for isolated environments and tests:

- `VAI_RUNTIME_DIR`: socket directory
- `VAI_STATE_DIR`: state/log directory

Without overrides, the daemon socket, lock, and logs live under `~/.config/vai/`, alongside `vai.toml` and `presets/`.

## Requirements

- Zig 0.16.0
- POSIX environment (macOS or Linux)
