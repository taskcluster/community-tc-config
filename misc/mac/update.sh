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
uid=$(id -u "${current_user}")

if [ -z "${current_user}" ] || [ -z "${uid}" ]; then
  echo "Cannot detect current user (${current_user}) or uid (${uid})" >&2
  exit 64
fi

cd /var/root
launchctl unload -w /Library/LaunchDaemons/com.mozilla.genericworker.plist
launchctl bootout "gui/${uid}" "/Users/${current_user}/Library/LaunchAgents/com.mozilla.genericworker.launchagent.plist"
rm -f current-task-user.json next-task-user.json tasks-resolved-count.txt directory-caches.json file-caches.json
cd /usr/local/bin
curl -L https://github.com/taskcluster/taskcluster/releases/download/v${VERSION}/generic-worker-multiuser-darwin-arm64 > generic-worker
curl -L https://github.com/taskcluster/taskcluster/releases/download/v${VERSION}/livelog-darwin-arm64 > livelog 
curl -L https://github.com/taskcluster/taskcluster/releases/download/v${VERSION}/start-worker-darwin-arm64 > start-worker
curl -L https://github.com/taskcluster/taskcluster/releases/download/v${VERSION}/taskcluster-proxy-darwin-arm64 > taskcluster-proxy
# in case the file wasn't already present, for any reason (such as they were manually deleted)
chmod a+x generic-worker livelog start-worker taskcluster-proxy
launchctl bootstrap "gui/${uid}" "/Users/${current_user}/Library/LaunchAgents/com.mozilla.genericworker.launchagent.plist"
launchctl load -w /Library/LaunchDaemons/com.mozilla.genericworker.plist
