#!/usr/bin/env bash

# This file is managed in https://github.com/taskcluster/community-tc-config
# (misc/mac/install-macos-updates.sh), and run on the macOS workers by
# imagesets/imageset.sh when UPDATE_MACOS=true.
#
# Installs the recommended software updates, other than upgrades to a newer
# major version of macOS, in the background: it stops the worker, and
# restarts the Mac when done. Prints the updates, or nothing if there are none.

set -eu
set -o pipefail

LOG=/var/log/install-macos-updates.log
major="$(sw_vers -productVersion | cut -d. -f1)"

# "* Label: <label>" lines are followed by "Title: <title>, Version: <version>, ..."
labels=()
while IFS=$'\t' read -r label title version; do
  if [[ "${title}" == macOS* ]] && [ "${version%%.*}" != "${major}" ]; then
    continue
  fi
  labels+=("${label}")
  echo "${title} ${version}"
done < <(softwareupdate --list 2> /dev/null | awk '
  /^\* Label: / { sub(/^\* Label: /, ""); label = $0; next }
  label != "" && /Title: / {
    title = $0; sub(/^.*Title: /, "", title); sub(/, Version: .*/, "", title)
    version = $0; sub(/^.*Version: /, "", version); sub(/,.*/, "", version)
    print label "\t" title "\t" version; label = ""
  }')

[ "${#labels[@]}" -gt 0 ] || exit 0

# Restarts even if softwareupdate fails, so that the worker starts again
nohup bash -c '
  launchctl bootout system/com.mozilla.genericworker || true
  softwareupdate --install --restart "$@"
  shutdown -r now
' install-macos-updates "${labels[@]}" > "${LOG}" 2>&1 < /dev/null &
