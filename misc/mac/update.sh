#!/usr/bin/env bash

# This file is managed in https://github.com/taskcluster/community-tc-config
# (misc/mac/update.sh), and installed on the macOS workers by imagesets/imageset.sh
# on every deployment. Don't change it on a worker, as the next deployment will
# overwrite it: change it in community-tc-config instead.

function retry {
  set +e
  local n=0
  local max=20
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed" >&2
        sleep_time=$((2 ** n))
        echo "Sleeping $sleep_time seconds..." >&2
        sleep $sleep_time
        echo "Attempt $n/$max:" >&2
      else
        echo "Failed after $n attempts." >&2
        exit 67
      fi
    }
  done
  set -e
}

set -eu
set -o pipefail

VERSION="$(retry curl -s https://api.github.com/repos/taskcluster/taskcluster/releases/latest | sed -n 's/.*"tag_name".*v//p' | sed 's/".*//')"
if [ -z "${VERSION}" ]; then
  echo "Cannot retrieve taskcluster version" >&2
  exit 64
fi

current_user=$(scutil <<< "show State:/Users/ConsoleUser" | sed -n 's/.*Name : //p')
uid=''
[ -n "${current_user}" ] && uid=$(id -u "${current_user}")

if [ -z "${current_user}" ] || [ -z "${uid}" ]; then
  echo "WARNING: Cannot detect current user (${current_user}) or uid (${uid})" >&2
fi

# Download the new binaries before stopping the worker, so that it keeps running
# if a download fails. They are renamed into place below, rather than
# overwriting the existing files: a binary that is overwritten while it is still
# running (e.g. a launch agent that hasn't exited yet) is killed by macOS
# (SIGKILL, code signature error) the next time it is run.
BINARIES="generic-worker livelog start-worker taskcluster-proxy"
cd /usr/local/bin
for binary in ${BINARIES}; do
  asset="${binary}-darwin-arm64"
  [ "${binary}" == "generic-worker" ] && asset="generic-worker-multiuser-darwin-arm64"
  retry curl -fsSL -o "${binary}.new" "https://github.com/taskcluster/taskcluster/releases/download/v${VERSION}/${asset}"
  chmod a+x "${binary}.new"
done

# Runs a command that stops a launchd service (<domain>/<label>), which fails
# if it isn't loaded, and fails only if the service is still loaded afterwards.
function stop-service {
  local service="${1}"
  shift
  local stop_failed=false
  "$@" || stop_failed=true
  local attempt
  for attempt in $(seq 30); do
    if ! launchctl print "${service}" > /dev/null 2>&1; then
      if "${stop_failed}"; then
        echo "WARNING: '$*' failed, probably because ${service} wasn't loaded. This can be a matter of timing, and doesn't mean that anything is wrong: ${service} isn't loaded now." >&2
      fi
      return 0
    fi
    sleep 1
  done
  echo "ERROR: ${service} is still loaded after running '$*'" >&2
  return 1
}

DAEMON_PLIST=/Library/LaunchDaemons/com.mozilla.genericworker.plist
AGENT_PLIST="/Users/${current_user}/Library/LaunchAgents/com.mozilla.genericworker.launchagent.plist"

cd /var/root
if ! stop-service system/com.mozilla.genericworker launchctl unload -w "${DAEMON_PLIST}"; then
  launchctl load -w "${DAEMON_PLIST}" || true
  exit 1
fi
if [ -n "${uid}" ] && ! stop-service "gui/${uid}/com.mozilla.genericworker.launchagent" launchctl bootout "gui/${uid}" "${AGENT_PLIST}"; then
  echo "Restarting the worker without updating it" >&2
  launchctl load -w "${DAEMON_PLIST}"
  exit 1
fi
rm -f current-task-user.json next-task-user.json tasks-resolved-count.txt directory-caches.json file-caches.json
cd /usr/local/bin
for binary in ${BINARIES}; do
  mv -f "${binary}.new" "${binary}"
done
status=0
if [ -n "${uid}" ] && ! launchctl bootstrap "gui/${uid}" "${AGENT_PLIST}"; then
  echo "ERROR: Couldn't bootstrap ${AGENT_PLIST} in gui/${uid}" >&2
  status=1
fi
launchctl load -w "${DAEMON_PLIST}"
exit "${status}"
