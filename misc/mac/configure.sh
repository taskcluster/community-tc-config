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
chown root:wheel /System/Volumes/Data/.metadata_never_index

launchctl disable system/com.apple.aned

/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on > /dev/null

chmod 755 /var/log/genericworker

# What relops set up (see README.md), which can't be done from here
function check {
  local description="${1}"
  shift
  "$@" > /dev/null 2>&1 || echo "WARNING: ${description} (see misc/mac/README.md)" >&2
}
check "System Integrity Protection isn't off" sh -c 'csrutil status | grep -q disabled'
check "FileVault isn't off" sh -c 'fdesetup status | grep -q "FileVault is Off"'
check "ssh (Remote Login) isn't on" sh -c 'systemsetup -getremotelogin | grep -q On'
check "Screen Sharing isn't on" sh -c 'launchctl print-disabled system | grep -q "\"com.apple.screensharing\" => enabled"'
check "the admin group doesn't have passwordless sudo" grep -q '^%admin[[:space:]].*NOPASSWD: ALL' /etc/sudoers
check "Xcode's licence isn't accepted" xcodebuild -license check
check "the Mac isn't enrolled in relops' MDM" sh -c 'profiles status -type enrollment | grep -q "MDM enrollment: Yes"'
check "the Skip Setup Assistant profile isn't installed" sh -c 'profiles show -type configuration | grep -q "Skip Setup Assistant"'
