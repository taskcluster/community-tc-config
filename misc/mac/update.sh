#!/usr/bin/env bash

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

cd /var/root
launchctl unload -w /Library/LaunchDaemons/com.mozilla.genericworker.plist
[ -n "${uid}" ] && launchctl bootout "gui/${uid}" "/Users/${current_user}/Library/LaunchAgents/com.mozilla.genericworker.launchagent.plist"
rm -f current-task-user.json next-task-user.json tasks-resolved-count.txt directory-caches.json file-caches.json
cd /usr/local/bin
for binary in ${BINARIES}; do
  mv -f "${binary}.new" "${binary}"
done
[ -n "${uid}" ] && launchctl bootstrap "gui/${uid}" "/Users/${current_user}/Library/LaunchAgents/com.mozilla.genericworker.launchagent.plist"
launchctl load -w /Library/LaunchDaemons/com.mozilla.genericworker.plist
