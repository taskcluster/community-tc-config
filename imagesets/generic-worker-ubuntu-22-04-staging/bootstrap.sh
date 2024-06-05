#!/bin/bash

set -exv
exec &> /var/log/bootstrap.log

##############################################################################
# TASKCLUSTER_REF can be a git commit SHA, a git branch name, or a git tag name
# (i.e. for a taskcluster version number, prefix with 'v' to make it a git tag)
TASKCLUSTER_REF='main'
##############################################################################

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
retry apt-get -y remove docker docker.io containerd runc
# build-essential is needed for running `go test -race` with the -vet=off flag as of go1.19
retry apt-get install -y apt-transport-https ca-certificates curl software-properties-common gzip python3-venv build-essential snapd

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
echo 'core' > /proc/sys/kernel/core_pattern

# create group for running snap
groupadd snap_sudo
echo '%snap_sudo ALL=(ALL:ALL) NOPASSWD: /usr/bin/snap' | EDITOR='tee -a' visudo

# build generic-worker/livelog/start-worker/taskcluster-proxy from ${TASKCLUSTER_REF} commit / branch / tag etc
retry apt-get install -y git tar
retry curl -fsSL 'https://dl.google.com/go/go1.22.0.linux-amd64.tar.gz' > go.tar.gz
tar xvfz go.tar.gz -C /usr/local
export HOME=/root
export GOPATH=~/go
export GOROOT=/usr/local/go
export PATH="${GOROOT}/bin:${GOPATH}/bin:${PATH}"
git clone https://github.com/taskcluster/taskcluster
cd taskcluster
git checkout "${TASKCLUSTER_REF}"
CGO_ENABLED=0 go install -tags multiuser -ldflags "-X main.revision=$(git rev-parse HEAD)" ./...
mv "${GOPATH}/bin"/* /usr/local/bin/

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

[Service]
Type=simple
ExecStart=/usr/local/bin/start-worker /etc/start-worker.yml
# log to console to make output visible in cloud consoles, and syslog for ease of
# redirecting to external logging services
StandardOutput=syslog+console
StandardError=syslog+console
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

retry apt-get install -y ubuntu-desktop ubuntu-gnome-desktop podman

# set podman registries conf
(
  echo '[registries.search]'
  echo 'registries=["docker.io"]'
) >> /etc/containers/registries.conf

# Installs the v4l2loopback kernel module
# used for the video device, and vkms
# required by Wayland
retry apt-get install -y linux-modules-extra-$(uname -r)
# needed for mutter to work with DRM rather than falling back to X11
grep -Fx vkms /etc/modules || echo vkms >> /etc/modules
# disable udev rule that tags platform-vkms with "mutter-device-ignore"
# ENV{ID_PATH}=="platform-vkms", TAG+="mutter-device-ignore"
sed '/platform-vkms/d' /lib/udev/rules.d/61-mutter.rules > /etc/udev/rules.d/61-mutter.rules

# install necessary packages for KVM
# https://help.ubuntu.com/community/KVM/Installation
retry apt-get install -y qemu-kvm bridge-utils

# See
#   * https://console.aws.amazon.com/support/cases#/6410417131/en
#   * https://bugzilla.mozilla.org/show_bug.cgi?id=1499054#c12
cat > /etc/cloud/cloud.cfg.d/01_network_renderer_policy.cfg << EOF
system_info:
    network:
      renderers: [ 'netplan', 'eni', 'sysconfig' ]
EOF

# snd-aloop support
echo 'options snd-aloop enable=1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1 index=0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31' > /etc/modprobe.d/snd-aloop.conf
echo 'snd-aloop' >> /etc/modules
# apt-get install -y linux-generic
# sed -i 's/GRUB_DEFAULT=.*/GRUB_DEFAULT="1>2"/' /etc/default/grub
# sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="splash"/' /etc/default/grub
# sed -i 's/GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="debug g"/' /etc/default/grub
# update-grub

end_time="$(date '+%s')"
echo "UserData execution took: $(($end_time - $start_time)) seconds"

# shutdown so that instance can be snapshotted
shutdown -h now
