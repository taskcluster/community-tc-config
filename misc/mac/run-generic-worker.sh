#!/usr/bin/env bash

log() {
  echo "$(date '+%Y/%m/%d %H:%M:%S') $*"
}

log "Deleting files from purged users..."
find /private/var/folders/ -nouser -delete
log "Finished deleting files from purged users."

log "Changing to home directory..."
cd ~
log "Current directory: $(pwd)"

log "Starting worker..."
/usr/local/bin/start-worker /etc/generic-worker/runner.yml
log "Worker started"
