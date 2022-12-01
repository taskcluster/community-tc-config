#!/bin/bash

set -exv
exec &> /var/log/bootstrap.log

# Version numbers ####################
TASKCLUSTER_REF='v45.0.0'
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

retry apt-get update
DEBIAN_FRONTEND=noninteractive retry apt-get upgrade -yq
retry apt-get -y remove docker docker.io containerd runc
# build-essential is needed for running `go test -race` with the -vet=off flag as of go1.19
retry apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common git tar python3-venv build-essential

# build generic-worker/livelog/start-worker/taskcluster-proxy from ${TASKCLUSTER_REF} commit / branch / tag etc
retry curl -L 'https://dl.google.com/go/go1.19.3.linux-amd64.tar.gz' > go.tar.gz
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
