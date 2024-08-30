#!/bin/csh

# Version numbers ####################
setenv TASKCLUSTER_VERSION v68.0.1
######################################

pkg update
pkg upgrade -y

pkg install -y gdm bash xorg gnome xorg-vfbserver

ln -s /usr/local/etc/gdm/custom.conf /etc/gdm3/custom.conf
ln -s /usr/bin/grep /bin/grep

cat >> /etc/rc.conf << EOF
gdm_enable="YES"
gnome_enable="YES"
dbus_enable="YES"
EOF

mkdir -p /usr/local/bin
cd /usr/local/bin
fetch -o generic-worker "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/generic-worker-multiuser-freebsd-arm64"
fetch -o start-worker "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/start-worker-freebsd-arm64"
fetch -o livelog "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/livelog-freebsd-arm64"
fetch -o taskcluster-proxy "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/taskcluster-proxy-freebsd-arm64"
chmod a+x generic-worker start-worker taskcluster-proxy livelog

mkdir -p /etc/generic-worker
mkdir -p /var/log/generic-worker
/usr/local/bin/generic-worker --version
/usr/local/bin/generic-worker new-ed25519-keypair --file /etc/generic-worker/ed25519_key

echo 127.0.1.1 taskcluster >> /etc/hosts

cat > /etc/start-worker.yml << EOF
provider:
    providerType: %MY_CLOUD%
worker:
    implementation: generic-worker
    path: /usr/local/bin/generic-worker
    configPath: /etc/generic-worker/config
cacheOverRestarts: /etc/start-worker-cache.json
EOF

shutdown -h now
