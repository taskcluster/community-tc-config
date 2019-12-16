#!/bin/bash

set -exv
exec &> /var/log/bootstrap.log

# Version numbers ####################
WORKER_RUNNER_VERSION='v1.0.0'
GENERIC_WORKER_VERSION='v16.5.6'
LIVELOG_VERSION='v1.1.0'
TASKCLUSTER_PROXY_VERSION='v5.1.0'
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

retry apt update
DEBIAN_FRONTEND=noninteractive apt upgrade -yq
retry apt install -y apt-transport-https ca-certificates curl software-properties-common gzip

# install docker
retry curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu bionic stable"
retry apt update
apt-cache policy docker-ce | grep -qF download.docker.com
retry apt install -y docker-ce
sleep 5
systemctl status docker | grep "Started Docker Application Container Engine"
usermod -aG docker ubuntu

cd /usr/local/bin
retry curl -L "https://github.com/taskcluster/generic-worker/releases/download/${GENERIC_WORKER_VERSION}/generic-worker-multiuser-linux-amd64" > generic-worker
retry curl -L "https://github.com/taskcluster/taskcluster-worker-runner/releases/download/${WORKER_RUNNER_VERSION}/start-worker-linux-amd64" > start-worker
retry curl -L "https://github.com/taskcluster/livelog/releases/download/${LIVELOG_VERSION}/livelog-linux-amd64" > livelog
retry curl -L "https://github.com/taskcluster/taskcluster-proxy/releases/download/${TASKCLUSTER_PROXY_VERSION}/taskcluster-proxy-linux-amd64" > taskcluster-proxy
chmod a+x generic-worker start-worker taskcluster-proxy livelog

mkdir -p /etc/generic-worker
mkdir -p /var/local/generic-worker
./generic-worker --version
./generic-worker new-ed25519-keypair --file /etc/generic-worker/ed25519_key

# ensure host 'taskcluster' resolves to localhost
echo 127.0.1.1 taskcluster >> /etc/hosts

# configure generic-worker to run on boot
cat > /lib/systemd/system/worker.service <<EOF
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

cat > /etc/start-worker.yml <<EOF
provider:
    providerType: %MY_CLOUD%
worker:
    implementation: generic-worker
    path: /usr/local/bin/generic-worker
    configPath: /etc/generic-worker/config
cacheOverRestarts: /etc/start-worker-cache.json
EOF

systemctl enable worker

retry apt install -y ubuntu-desktop ubuntu-gnome-desktop

# See
#   * https://console.aws.amazon.com/support/cases#/6410417131/en
#   * https://bugzilla.mozilla.org/show_bug.cgi?id=1499054#c12
cat > /etc/cloud/cloud.cfg.d/01_network_renderer_policy.cfg << EOF
system_info:
    network:
      renderers: [ 'netplan', 'eni', 'sysconfig' ]
EOF

end_time="$(date '+%s')"
echo "UserData execution took: $(($end_time-$start_time)) seconds"

# shutdown so that instance can be snapshotted
shutdown now
