#!/usr/bin/env bash

# One-time setup of a new macOS worker, run as root on it (see README.md),
# before imagesets/imageset.sh installs the rest.

set -eu

mkdir -p /etc/generic-worker /var/log/genericworker /usr/local/bin
if ! grep -q '^  staticSecret: ' /etc/generic-worker/runner.yml 2> /dev/null; then
  read -r -s -p "The worker's staticSecret: " secret
  echo
  (umask 077 && printf 'provider:\n  staticSecret: %s\n' "${secret}" > /etc/generic-worker/runner.yml)
fi
