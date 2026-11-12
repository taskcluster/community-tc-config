#!/usr/bin/env bash

# This file is managed in https://github.com/taskcluster/community-tc-config
# (misc/mac/configure.sh), and run on the macOS workers by imagesets/imageset.sh
# on every deployment, so that their settings don't drift apart.

set -eu

# Automatic updates, including of macOS
for key in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates ConfigDataInstall CriticalUpdateInstall; do
  defaults write /Library/Preferences/com.apple.SoftwareUpdate "${key}" -bool true
done

# Spotlight off, as in generic-worker's docs: mdutil needs mds running
launchctl load -w /System/Library/LaunchDaemons/com.apple.metadata.mds.plist 2> /dev/null || true
mdutil -a -i off > /dev/null || echo "WARNING: couldn't turn off Spotlight indexing" >&2
touch /System/Volumes/Data/.metadata_never_index

launchctl disable system/com.apple.aned
