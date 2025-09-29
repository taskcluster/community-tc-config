# macOS Worker Files

This directory contains configuration files and scripts extracted from static Taskcluster macOS workers. These files are preserved to avoid having to recreate them from scratch.

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
- Changes to home directory
- Launches the worker using `/usr/local/bin/start-worker` with config `/etc/generic-worker/runner.yml`

### [runner.yml](runner.yml)
Taskcluster worker configuration file used by `start-worker`.

### [update.sh](update.sh)
Maintenance script for updating Taskcluster worker components:
- Fetches the latest Taskcluster version from GitHub API
- Stops existing worker services (LaunchDaemon and LaunchAgent)
- Downloads updated binaries: `generic-worker`, `livelog`, `start-worker`, `taskcluster-proxy`
- Restarts the worker services
- Includes retry logic with exponential backoff for network operations
