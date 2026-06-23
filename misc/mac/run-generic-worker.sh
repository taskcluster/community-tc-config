#!/usr/bin/env bash

log() {
  echo "$(date '+%Y/%m/%d %H:%M:%S') $*"
}

log "Deleting files from purged users..."
find /private/var/folders/ -nouser -delete
log "Finished deleting files from purged users."

# ANE daemon should be disabled, but delete just in case
log "Clearing Apple Neural Engine model cache..."
rm -rf /Library/Caches/com.apple.aned
log "Finished clearing ANE cache."

# Spotlight should also be disabled, but delete just in case
log "Clearing Spotlight index..."
rm -rf /System/Volumes/Data/.Spotlight-V100
log "Finished clearing Spotlight index."

log "Removing BTM database (see https://github.com/taskcluster/community-tc-config/issues/983)..."
rm -f /var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm
log "Finished removing BTM database."

log "Changing to home directory..."
cd ~
log "Current directory: $(pwd)"

log "Starting worker..."
/usr/local/bin/start-worker /etc/generic-worker/runner.yml
log "Worker started"
