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

# Reset the Background Task Management (BTM) database, see:
#   * https://github.com/taskcluster/community-tc-config/issues/983
BTM_DIR=/var/db/com.apple.backgroundtaskmanagement
BTM_DB="${BTM_DIR}/BackgroundItems-v16.btm"
BTM_MAX_BYTES=2621440   # 2.5 MiB; the crash-loop has been observed around 4 MB
btm_size=0
[ -f "${BTM_DB}" ] && btm_size="$(stat -f%z "${BTM_DB}" 2>/dev/null || echo 0)"
if [ "${btm_size}" -ge "${BTM_MAX_BYTES}" ]; then
  log "BTM database is ${btm_size} bytes (>= ${BTM_MAX_BYTES}) - resetting (issue #983)..."
  rm -f "${BTM_DIR}"/BackgroundItems-v*.btm
  killall -9 backgroundtaskmanagementd 2>/dev/null || true
  log "Finished resetting BTM database."
fi

log "Changing to home directory..."
cd ~
log "Current directory: $(pwd)"

log "Starting worker..."
/usr/local/bin/start-worker /etc/generic-worker/runner.yml
log "Worker started"
