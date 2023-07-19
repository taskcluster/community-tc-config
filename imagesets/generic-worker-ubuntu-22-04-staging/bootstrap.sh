#!/bin/bash

set -exv
exec &> /var/log/bootstrap.log

##############################################################################
# TASKCLUSTER_REF can be a git commit SHA, a git branch name, or a git tag name
# (i.e. for a taskcluster version number, prefix with 'v' to make it a git tag)
TASKCLUSTER_REF='bb38aaf520c9a39463d1846b5b0eda87acf8a29b'
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

retry apt-get update
DEBIAN_FRONTEND=noninteractive retry apt-get upgrade -yq
retry apt-get -y remove docker docker.io containerd runc
# build-essential is needed for running `go test -race` with the -vet=off flag as of go1.19
retry apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common git tar python3-venv build-essential

# # install docker
# retry curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
# echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
#   $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
# retry apt-get update
# retry apt-get install -y docker-ce docker-ce-cli containerd.io
# retry docker run hello-world

if [[ "%MY_CLOUD%" == "google" ]]; then
    # installs the v4l2loopback kernel module
    # used for the video device
    # only required on gcp
    retry apt-get install linux-modules-extra-gcp -y
fi

# build generic-worker/livelog/start-worker/taskcluster-proxy from ${TASKCLUSTER_REF} commit / branch / tag etc
retry curl -fsSL 'https://dl.google.com/go/go1.20.5.linux-amd64.tar.gz' > go.tar.gz
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

retry apt-get install -y ubuntu-desktop ubuntu-gnome-desktop

# Install v4 of podman from kubic rather than regular ubuntu package
# See:
#   * https://github.com/mozilla/community-tc-config/pull/580
#   * https://podman.io/docs/installation#ubuntu

mkdir -p /etc/apt/keyrings
retry curl -fsSL https://download.opensuse.org/repositories/devel:kubic:libcontainers:unstable/xUbuntu_$(lsb_release -rs)/Release.key \
  | gpg --dearmor > /etc/apt/keyrings/devel_kubic_libcontainers_unstable.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/devel_kubic_libcontainers_unstable.gpg]\
    https://download.opensuse.org/repositories/devel:kubic:libcontainers:unstable/xUbuntu_$(lsb_release -rs)/ /" \
  > /etc/apt/sources.list.d/devel:kubic:libcontainers:unstable.list
retry apt-get update -qq
retry apt-get -qq -y install podman

# set podman registries conf
(
  echo '[registries.search]'
  echo 'registries=["docker.io"]'
) >> /etc/containers/registries.conf

# See
#   * https://console.aws.amazon.com/support/cases#/6410417131/en
#   * https://bugzilla.mozilla.org/show_bug.cgi?id=1499054#c12
cat > /etc/cloud/cloud.cfg.d/01_network_renderer_policy.cfg << EOF
system_info:
    network:
      renderers: [ 'netplan', 'eni', 'sysconfig' ]
EOF

end_time="$(date '+%s')"
echo "UserData execution took: $(($end_time - $start_time)) seconds"

# shutdown so that instance can be snapshotted
shutdown -h now
