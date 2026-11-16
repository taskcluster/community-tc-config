#!/usr/bin/env bash

# This file is managed in https://github.com/taskcluster/community-tc-config
# (misc/mac/configure.sh), and run on the macOS workers by imagesets/imageset.sh
# on every deployment, so that their settings don't drift apart.

set -eu

# No automatic updates (they need idle time that the workers, which reboot
# after every task, don't get): install-macos-updates.sh installs them
# deliberately. Only XProtect and other data files are installed automatically.
for key in AutomaticDownload AutomaticallyInstallMacOSUpdates CriticalUpdateInstall; do
  defaults write /Library/Preferences/com.apple.SoftwareUpdate "${key}" -bool false
done
for key in AutomaticCheckEnabled ConfigDataInstall; do
  defaults write /Library/Preferences/com.apple.SoftwareUpdate "${key}" -bool true
done

# Never sleep, and restart after a power failure
pmset -a sleep 0 displaysleep 0 disksleep 0 standby 0 autorestart 1

# Relops' MDM installs the puppet agent, which nothing uses here (it can't
# reach a puppet server), and which retries forever
launchctl disable system/puppet
launchctl bootout system/puppet 2> /dev/null || true
rm -f /var/log/puppetlabs/puppet/puppet.log

# Spotlight off, as in generic-worker's docs: mdutil needs mds running
launchctl load -w /System/Library/LaunchDaemons/com.apple.metadata.mds.plist 2> /dev/null || true
mdutil -a -i off > /dev/null || echo "WARNING: couldn't turn off Spotlight indexing" >&2
touch /System/Volumes/Data/.metadata_never_index

launchctl disable system/com.apple.aned
