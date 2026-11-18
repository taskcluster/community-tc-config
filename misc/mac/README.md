# macOS Workers

This directory sets up and maintains the static Taskcluster macOS workers
(`proj-taskcluster/gw-ci-macos` in firefox-ci: `macmini-m4-126` and
`macmini-m4-127`), so that they are all set up the same way. It is their only
source: `imagesets/imageset.sh prod` (or `all`) installs these files on each
worker (see `MAC_FILES` in [run.sh](../../imagesets/container/run.sh)) and runs
them, so any changes made directly on a worker are overwritten. Change them here
instead.

A worker's setup has three parts:

1. What relops provide (see below), which this directory can't do, but which
   `configure.sh` checks on every deployment, warning about anything missing.
2. The one-time setup of a new worker ([setup.sh](setup.sh) and the steps
   below).
3. Everything else, which `imageset.sh` does on every deployment, so that the
   workers stay the same.

## What relops provide

- macOS installed, with System Integrity Protection off. Turning SIP off needs
  someone at the Mac in the datacenter, which relops no longer do, so **don't
  erase a worker**: erasing it re-enrolls it in MDM with SIP on, and without
  our accounts or ssh access. Clean it up in place instead, or plan a
  reinstall with relops.
- Enrollment (DEP) in relops' SimpleMDM, in the group `proj-taskcluster
  gw-ci-macos`, which only has the "System Settings - Skip Setup Assistant -
  All Screens" profile, so that task users don't get first-login wizards. The
  group has no apps and no update settings. If relops ever assign a worker an
  app, SimpleMDM also installs munki and its agent on it to deliver it.
- An `administrator` account in the `admin` group, with passwordless `sudo`
  for `%admin`, and relops' packages `relops_key_admin`, `relops-ssh` and
  `Sudoers`, plus the `puppet-agent` package (which `configure.sh` disables,
  as nothing uses it).
- ssh (Remote Login) and Screen Sharing on, FileVault off.
- Xcode in `/Applications` (26.2 on the current workers), with its licence
  accepted.

## Setting up a new worker

1. Ask relops for the above.
2. Add its `administrator` password to the password store
   (`mdc1/generic-worker-ci/<host>`), and its host key to
   [mac_known_hosts](../../imagesets/mac_known_hosts)
   (`ssh-keyscan -t ed25519 <host>`).
3. Run `sudo bash setup.sh` on it, with its `staticSecret` (from its worker
   pool's definition).
4. Add it to `MAC_HOSTS` in [run.sh](../../imagesets/container/run.sh), and run
   `imagesets/imageset.sh prod`, which does the rest (below).

## What every deployment does

`imageset.sh` installs these files, runs `configure.sh`, drains the worker
(`worker.sh`), runs `update.sh`, then `install-macos-updates.sh`, on one worker
at a time.

### [configure.sh](configure.sh)
- Automatic updates off, other than of XProtect and other data files (see
  `install-macos-updates.sh`).
- Automatic login back on, if an interrupted `install-macos-updates.sh` left
  it off.
- No sleep, and restart after a power failure (`pmset`).
- The puppet agent off.
- Spotlight indexing off, as in generic-worker's docs (`mdutil` and
  `.metadata_never_index`), and the Apple Neural Engine daemon (`aned`) off.
- The firewall on, and `/var/log/genericworker` readable.
- Checks what relops provide (above), and warns about anything missing.

### [authorized_keys](authorized_keys)
The ssh keys of the `administrator` account: relops', for support, and TCEng's.
`imageset.sh` itself logs in with the password.

### [update.sh](update.sh)
Updates the worker to the latest Taskcluster release. `imageset.sh` first
drains the worker (see `worker.sh`), so that stopping it doesn't stop a task.
- Downloads `generic-worker`, `livelog`, `start-worker` and
  `taskcluster-proxy`, before stopping the worker, so that it keeps running if
  a download fails.
- Stops the worker (LaunchDaemon and LaunchAgent), failing only if it is still
  loaded afterwards.
- Renames the new binaries into place, rather than overwriting the existing
  files, as macOS kills a binary that was overwritten while it was running, the
  next time it is run.
- Restarts the worker.

### [worker.sh](worker.sh)
- `drain`: asks generic-worker to stop claiming tasks, and to exit once its
  task (if any) has finished (SIGINT), without aborting the task or restarting
  the Mac. `imageset.sh` waits up to 4 hours for it to exit, and then fails
  for that worker, which no longer claims tasks.
- `status`: whether the worker is stopped, running, or ready (running, with
  the task user's launch agent, so it can run tasks).

### [install-macos-updates.sh](install-macos-updates.sh)
Installs the recommended software updates (macOS, Command Line Tools, Safari),
other than a new major version of macOS. With no updates to install, it changes
nothing. Otherwise `imageset.sh`, one worker at a time:
- Asks generic-worker to stop claiming tasks and to exit once its task has
  finished (SIGINT), and waits for it to exit.
- Turns automatic login off and logs out the task user. Otherwise, after an
  update, macOS logs back in the user who was logged in when it was installed,
  once, rather than generic-worker's next task user, and the worker gives up
  waiting for that user's launch agent.
- Installs the updates, with the administrator's password on stdin (on Apple
  silicon, installing a macOS update needs a volume owner's password), and
  waits for the worker to restart. If it isn't on the new version of macOS,
  it tries again, up to 3 times.
- Turns automatic login back on, restarts the worker, and waits for its worker
  to be ready for tasks, whether or not the updates were installed.

As relops do for their CI workers, updates are installed deliberately rather
than automatically: macOS wouldn't install them by itself anyway, as the
workers restart after every task. Skip it with `UPDATE_MACOS=false`.

### [com.mozilla.genericworker.plist](com.mozilla.genericworker.plist)
The LaunchDaemon that runs `run-generic-worker.sh` as root at boot, logging to
`/var/log/genericworker/`.

### [run-generic-worker.sh](run-generic-worker.sh)
Run at every boot, before starting the worker:
- Deletes files of deleted task users in `/private/var/folders/`.
- Clears the Apple Neural Engine model cache (`/Library/Caches/com.apple.aned`)
  and the Spotlight index, which otherwise grow from transient task users.
- Resets the Background Task Management database if it exceeds 2.5 MiB (see
  [#983](https://github.com/taskcluster/community-tc-config/issues/983)).
- Creates the worker's signing key, if it doesn't have one yet.
- Starts the worker with `start-worker` and `runner.yml`. generic-worker
  creates a new user for each task, logs it in, and installs its own
  LaunchAgent for it.

### [runner.yml](runner.yml)
The worker's configuration, installed as `/etc/generic-worker/runner.yml`.
`@WORKER_ID@` is replaced with the worker's hostname, `@PUBLIC_IP@` with its
public IP address (as seen from the internet), `@STATIC_SECRET@` with the
`staticSecret` in the worker's existing `runner.yml`, so that the secret isn't
stored in this repository, and `@MISC_MAC_COMMIT@` with the commit that last
changed this directory. As the pool is static, its worker configuration is only
here (rather than in fxci-config's worker pool), including
`workerTypeMetadata.machine-setup`, which links to `update.sh` at that commit,
like the cloud workers' images' links to their bootstrap scripts (see
`config/imagesets.yml`).
