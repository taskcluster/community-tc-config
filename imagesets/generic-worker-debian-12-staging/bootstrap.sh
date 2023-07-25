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

retry apt-get update
DEBIAN_FRONTEND=noninteractive retry apt-get upgrade -yq
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do retry apt-get -y remove $pkg; done
# build-essential is needed for running `go test -race` with the -vet=off flag as of go1.19
retry apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common git tar python3-venv build-essential

# install docker
install -m 0755 -d /etc/apt/keyrings
retry curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | tee /etc/apt/sources.list.d/docker.list
retry apt-get update
retry apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
retry docker run hello-world

if [[ "%MY_CLOUD%" == "google" ]]; then
    # installs the v4l2loopback kernel module
    # used for the video device
    # only required on gcp
    retry apt-get install linux-modules-extra-gcp -y
fi

# build generic-worker/livelog/start-worker/taskcluster-proxy from ${TASKCLUSTER_REF} commit / branch / tag etc
retry curl -fsSL 'https://dl.google.com/go/go1.20.6.linux-amd64.tar.gz' > go.tar.gz
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

DEBIAN_FRONTEND=noninteractive retry apt-get install -y gdm3

retry apt-get install -y podman

# set podman registries conf
(
  echo '[registries.search]'
  echo 'registries=["docker.io"]'
) >> /etc/containers/registries.conf

end_time="$(date '+%s')"
echo "UserData execution took: $(($end_time - $start_time)) seconds"

# shutdown so that instance can be snapshotted
shutdown -h now
