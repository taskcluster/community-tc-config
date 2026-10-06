# macOS Worker Files

This directory contains the configuration files and scripts of the static
Taskcluster macOS workers (`proj-taskcluster/gw-ci-macos` in firefox-ci). This
repository is their only source: `imagesets/imageset.sh all` installs them on
each worker (see `MAC_FILES` in [imageset.sh](../../imagesets/imageset.sh))
before updating it, so any changes made directly on a worker are overwritten.
Change them here instead.

## Files

### [com.mozilla.genericworker.plist](com.mozilla.genericworker.plist)
LaunchDaemon configuration file that automatically starts the generic worker service on macOS. It defines:
- Service label: `com.mozilla.genericworker`
- Executable: `/usr/local/bin/run-generic-worker.sh`
- Logging configuration (stdout/stderr to `/var/log/genericworker/`)
- Runs as root with network dependency

### [run-generic-worker.sh](run-generic-worker.sh)
Startup script executed by the LaunchDaemon that:
- Cleans up files from purged users in `/private/var/folders/`
- Clears the Apple Neural Engine model cache (`/Library/Caches/com.apple.aned`)
- Clears the Spotlight index, which otherwise grow unbounded from transient task users
- Resets the Background Task Management database if it exceeds 2.5MiB (see [#983](https://github.com/taskcluster/community-tc-config/issues/983))
- Changes to home directory
- Launches the worker using `/usr/local/bin/start-worker` with config `/etc/generic-worker/runner.yml`

### [runner.yml](runner.yml)
Taskcluster worker configuration file used by `start-worker`, installed as
`/etc/generic-worker/runner.yml`. `@WORKER_ID@` is replaced with the worker's
hostname, `@PUBLIC_IP@` with its public IP address (as seen from the internet),
and `@STATIC_SECRET@` with the `staticSecret` in the worker's existing
`runner.yml`, so that the secret isn't stored in this repository.

### [update.sh](update.sh)
Maintenance script for updating Taskcluster worker components:
- Fetches the latest Taskcluster version from GitHub API
- Downloads updated binaries: `generic-worker`, `livelog`, `start-worker`, `taskcluster-proxy`
- Stops existing worker services (LaunchDaemon and LaunchAgent)
- Renames the new binaries into place, rather than overwriting the existing
  files, as macOS kills a binary that was overwritten while it was running, the
  next time it is run
- Restarts the worker services
- Includes retry logic with exponential backoff for network operations
