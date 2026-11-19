#!/usr/bin/env bash

# This file is managed in https://github.com/taskcluster/community-tc-config
# (misc/mac/install-macos-updates.sh), and run on the macOS workers by
# imagesets/imageset.sh, unless UPDATE_MACOS=false. imageset.sh runs, in order:
#
#   list     Prints the recommended software updates, other than upgrades to a
#            newer major version of macOS, or nothing if there are none.
#            Changes nothing.
#   (worker.sh drain, and imageset.sh waits for the worker to stop)
#   prepare  Logs out the task user, with automatic login off (/etc/kcpassword
#            set aside), so that macOS doesn't log the task user back in once
#            after the update (its onetimeAutoLogin), rather than
#            generic-worker's next task user.
#   install  Installs the updates in the background, and restarts the Mac. On
#            Apple silicon, installing a macOS update needs a volume owner's
#            password: the administrator's, read from stdin.
#   restore  Turns automatic login back on. imageset.sh then runs update.sh,
#            which starts the worker: generic-worker creates its next task user,
#            sets up automatic login for it, and restarts the Mac.

set -eu
set -o pipefail

LOG=/var/log/install-macos-updates.log
KCPASSWORD=/etc/kcpassword
KCPASSWORD_ASIDE=/etc/kcpassword.install-macos-updates

# Prints the updates' labels, titles and versions, tab-separated
function updates {
  local major list attempt
  major="$(sw_vers -productVersion | cut -d. -f1)"
  # softwareupdate --list can print nothing, rather than an error, e.g. just
  # after a restart, so its list is only trusted when it says what it found
  for attempt in 1 2 3 4 5 6; do
    list="$(softwareupdate --list 2>&1)" || true
    if grep -qE '^Software Update found|No new software available' <<< "${list}"; then
      break
    fi
    if [ "${attempt}" == 6 ]; then
      echo "softwareupdate --list didn't list the updates: ${list}" >&2
      return 1
    fi
    sleep 30
  done
  # "* Label: <label>" lines are followed by "Title: <title>, Version: <version>, ..."
  awk '
    /^\* Label: / { sub(/^\* Label: /, ""); label = $0; next }
    label != "" && /Title: / {
      title = $0; sub(/^.*Title: /, "", title); sub(/, Version: .*/, "", title)
      version = $0; sub(/^.*Version: /, "", version); sub(/,.*/, "", version)
      print label "\t" title "\t" version; label = ""
    }' <<< "${list}" | while IFS=$'\t' read -r label title version; do
    if [[ "${title}" == macOS* ]] && [ "${version%%.*}" != "${major}" ]; then
      continue
    fi
    printf '%s\t%s\t%s\n' "${label}" "${title}" "${version}"
  done
}

function console-user {
  stat -f %Su /dev/console
}

case "${1:-}" in
  list)
    updates | cut -f 2,3 | tr '\t' ' '
    ;;
  prepare)
    # Before logging out: macOS logs the user in again after a logout, too
    if [ -f "${KCPASSWORD}" ]; then
      mv "${KCPASSWORD}" "${KCPASSWORD_ASIDE}"
    fi
    user="$(console-user)"
    if [ "${user}" != root ]; then
      launchctl bootout "gui/$(id -u "${user}")" 2> /dev/null || true
      for _ in $(seq 60); do
        [ "$(console-user)" == root ] && break
        sleep 1
      done
      if [ "$(console-user)" != root ]; then
        echo "${user} is still logged in" >&2
        exit 1
      fi
    fi
    ;;
  install)
    # Started again at boot, after an earlier attempt's restart, it's only
    # waiting for a task user to log in (which they don't, with automatic login
    # off). The LaunchDaemon stays loaded, for update.sh.
    pkill -f '^/usr/local/bin/generic-worker run' || true
    password=""
    IFS= read -r password || true
    labels=()
    while IFS=$'\t' read -r label _; do
      labels+=("${label}")
    done < <(updates)
    [ "${#labels[@]}" -gt 0 ] || exit 0
    if [ -z "${password}" ]; then
      echo "No password on stdin, which installing macOS updates needs" >&2
      exit 1
    fi
    # Only root can read it; it's deleted as softwareupdate starts
    password_file="$(mktemp /var/root/install-macos-updates.XXXXXX)"
    printf '%s\n' "${password}" > "${password_file}"
    # When an update needs a restart, softwareupdate restarts the Mac itself,
    # once it has prepared the update (which takes minutes): restarting before
    # then would skip the update. Otherwise, or if softwareupdate fails, or
    # doesn't restart within an hour, this restarts the Mac.
    nohup bash -c '
      log="${1}"
      password_file="${2}"
      shift 2
      status=0
      { rm -f "${password_file}"; softwareupdate --install --restart --user administrator --stdinpass "$@"; } < "${password_file}" || status=$?
      if [ "${status}" == 0 ] && grep -q "^Restarting" "${log}"; then
        sleep 3600
      fi
      shutdown -r now
    ' install-macos-updates "${LOG}" "${password_file}" "${labels[@]}" > "${LOG}" 2>&1 < /dev/null &
    ;;
  restore)
    if [ -f "${KCPASSWORD_ASIDE}" ]; then
      mv "${KCPASSWORD_ASIDE}" "${KCPASSWORD}"
    fi
    ;;
  *)
    echo "Usage: ${0} list|prepare|install|restore" >&2
    exit 64
    ;;
esac
