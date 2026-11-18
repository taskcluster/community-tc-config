#!/usr/bin/env bash

# This file is managed in https://github.com/taskcluster/community-tc-config
# (misc/mac/worker.sh), and run on the macOS workers by imagesets/imageset.sh,
# before it stops the worker (to update it, or to install macOS updates):
#
#   drain   Asks generic-worker to stop claiming tasks, and to exit once its
#           task (if any) has finished (SIGINT: it doesn't abort the task, or
#           restart the Mac). imageset.sh waits for it to exit.
#   status  Prints the worker's state: stopped, running, or ready (running,
#           with the task user's launch agent, so it can run tasks).

set -eu
set -o pipefail

case "${1:-}" in
  drain)
    pkill -INT -f '^/usr/local/bin/generic-worker run' || true
    ;;
  status)
    if ! pgrep -q -f '^/usr/local/bin/generic-worker run'; then
      echo stopped
    elif pgrep -q -f '^/usr/local/bin/generic-worker launch-agent'; then
      echo ready
    else
      echo running
    fi
    ;;
  *)
    echo "Usage: ${0} drain|status" >&2
    exit 64
    ;;
esac
