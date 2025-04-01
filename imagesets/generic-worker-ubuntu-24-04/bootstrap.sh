#!/bin/bash

set -exv
exec &> /var/log/bootstrap.log

# Version numbers ####################
TASKCLUSTER_VERSION='v83.4.0'
######################################

function retry {
  set +e
  local n=0
  local max=10
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed" >&2
        sleep_time=$((2 ** n))
        echo "Sleeping $sleep_time seconds..." >&2
        sleep $sleep_time
        echo "Attempt $n/$max:" >&2
      else
        echo "Failed after $n attempts." >&2
        exit 1
      fi
    }
  done
  set -e
}

start_time="$(date '+%s')"

case "$(uname -m)" in
  x86_64)
    ARCH=amd64
    ;;
  aarch64)
    ARCH=arm64
    ;;
  *)
    echo "Unsupported architecture '$(uname -m)' - currently bootstrap.sh only supports architectures x86_64 and aarch64" >&2
    exit 64
    ;;
esac

retry apt-get update
DEBIAN_FRONTEND=noninteractive retry apt-get upgrade -yq
retry apt-get remove -y docker docker.io containerd runc
# build-essential is needed for running `go test -race` with the -vet=off flag as of go1.19
retry apt-get install -y apt-transport-https ca-certificates curl software-properties-common gzip python3-venv build-essential snapd crudini

# needed for kvm, see https://help.ubuntu.com/community/KVM/Installation
retry apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils

# install docker
retry curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
retry apt-get update
retry apt-get install -y docker-ce docker-ce-cli containerd.io
retry docker run hello-world

# configure kvm vmware backdoor
# this enables a vmware compatible interface for kvm, and is needed for some fuzzing tasks
cat > /etc/modprobe.d/kvm-backdoor.conf << "EOF"
options kvm enable_vmware_backdoor=y
EOF

# configure core dumps to be in the process' current directory with filename 'core'
# (required for 3 legacy JS engine fuzzers)
echo "kernel.core_pattern = core" >> /etc/sysctl.d/90-custom.conf

# fix 'bugmon-process: error: rr needs /proc/sys/kernel/perf_event_paranoid <= 1, but it is 4'
echo 'kernel.perf_event_paranoid = 1' >> /etc/sysctl.d/90-custom.conf

# create group for running snap
groupadd snap_sudo
echo '%snap_sudo ALL=(ALL:ALL) NOPASSWD: /usr/bin/snap' | EDITOR='tee -a' visudo

cd /usr/local/bin
retry curl -fsSL "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/generic-worker-multiuser-linux-${ARCH}" > generic-worker
retry curl -fsSL "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/start-worker-linux-${ARCH}" > start-worker
retry curl -fsSL "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/livelog-linux-${ARCH}" > livelog
retry curl -fsSL "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/taskcluster-proxy-linux-${ARCH}" > taskcluster-proxy
chmod a+x generic-worker start-worker taskcluster-proxy livelog

mkdir -p /etc/generic-worker
mkdir -p /var/local/generic-worker
/usr/local/bin/generic-worker --version
/usr/local/bin/generic-worker new-ed25519-keypair --file /etc/generic-worker/ed25519_key

# ensure host 'taskcluster' resolves to localhost
echo 127.0.1.1 taskcluster >> /etc/hosts

# configure generic-worker to run on boot
cat > /lib/systemd/system/worker.service << EOF
[Unit]
Description=Start TC worker
# start once networking is online
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/start-worker /etc/start-worker.yml
# log to console to make output visible in cloud consoles, and syslog for ease of
# redirecting to external logging services
StandardOutput=journal+console
StandardError=journal+console
User=root

[Install]
RequiredBy=graphical.target
EOF

cat > /etc/start-worker.yml << EOF
provider:
    providerType: %MY_CLOUD%
worker:
    implementation: generic-worker
    path: /usr/local/bin/generic-worker
    configPath: /etc/generic-worker/config
cacheOverRestarts: /etc/start-worker-cache.json
EOF

systemctl enable worker

# Installs the snd-aloop, v4l2loopback kernel modules
# used for the audio/video devices, and vkms
# required by Wayland
#
# Installs the extra kernel modules for the currently
# running kernel version as well as the cloud-specific
# meta-package in case we upgrade to a new kernel version
# on reboot
retry apt-get install -y linux-modules-extra-$(uname -r)
case '%MY_CLOUD%' in
  google)
    retry apt-get install -y linux-modules-extra-gcp
    ;;
  aws)
    retry apt-get install -y linux-modules-extra-aws
    ;;
esac

retry apt-get install -y ubuntu-desktop ubuntu-gnome-desktop podman gnome-initial-setup-

if [ '%MY_CLOUD%' == 'google' ]; then
    # this is neccessary in GCP because after installing gnome desktop both NetworkManager and systemd-networkd are enabled
    # which leads to https://bugs.launchpad.net/ubuntu/jammy/+source/systemd/+bug/2036358
    systemctl disable systemd-networkd-wait-online.service
fi

# set podman registries conf
(
  echo '[registries.search]'
  echo 'registries=["docker.io"]'
) >> /etc/containers/registries.conf

# needed for mutter to work with DRM rather than falling back to X11
grep -Fx vkms /etc/modules || echo vkms >> /etc/modules
# disable udev rule that tags platform-vkms with "mutter-device-ignore"
# ENV{ID_PATH}=="platform-vkms", TAG+="mutter-device-ignore"
sed '/platform-vkms/d' /lib/udev/rules.d/61-mutter.rules > /etc/udev/rules.d/61-mutter.rules

echo 'options snd-aloop enable=1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1 index=0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31' > /etc/modprobe.d/snd-aloop.conf
echo 'snd-aloop' >> /etc/modules

#
# dconf settings
#
cat > /etc/dconf/profile/user << EOF
user-db:user
system-db:local
EOF

mkdir /etc/dconf/db/local.d/
# dconf user settings
cat > /etc/dconf/db/local.d/00-tc-gnome-settings << EOF
# /org/gnome/desktop/session/idle-delay
[org/gnome/desktop/session]
idle-delay=uint32 0

# /org/gnome/desktop/lockdown/disable-lock-screen
[org/gnome/desktop/lockdown]
disable-lock-screen=true
EOF

# make dbus read the new configuration
dconf update

#
# gdm3 settings  
#
# in [daemon] block of /etc/gdm3/custom.conf we need:
#
# XorgEnable=false
crudini --set /etc/gdm3/custom.conf daemon XorgEnable 'false'

#
# gdm wait service file
#
# This hack is required because without we end up in a situation where the
# wayland seat is in a weird state and consequences are:
#    - either x11 session
#    - either xwayland fallback
#    - either wayland but with missing keyboard capability that breaks
#        things including copy/paste
mkdir -p /etc/systemd/system/gdm.service.d/
cat > /etc/systemd/system/gdm.service.d/gdm-wait.conf << EOF
[Unit]
Description=Extra 10s wait

[Service]
ExecStartPre=/bin/sleep 10
EOF

#
# write mutter's monitors.xml
#
cat > /etc/xdg/monitors.xml << EOF
<monitors version="2">
  <configuration>
    <logicalmonitor>
      <x>0</x>
      <y>0</y>
      <scale>1</scale>
      <primary>yes</primary>
      <monitor>
        <monitorspec>
          <connector>Virtual-1</connector>
          <vendor>unknown</vendor>
          <product>unknown</product>
          <serial>unknown</serial>
        </monitorspec>
        <mode>
          <width>1920</width>
          <height>1080</height>
          <rate>60.000</rate>
        </mode>
      </monitor>
    </logicalmonitor>
  </configuration>
</monitors>
EOF

# avoid unnecessary shutdowns during worker startups
systemctl disable unattended-upgrades

end_time="$(date '+%s')"
echo "UserData execution took: $(($end_time - $start_time)) seconds"

# shutdown so that instance can be snapshotted
shutdown -h now
