#!/bin/bash

set -exv
exec &> /var/log/bootstrap.log

WORKER_CERT="$(dirname $(realpath $0))/worker-cert.pem"

for CERT_FILE in /etc/star_taskcluster-worker_net.crt /etc/taskcluster/secrets/worker_livelog_tls_cert; do
  if [ -f "${CERT_FILE}" ]; then
    # use tee rather than cp so that file owner/group and read/write/execute
    # permissions are retained
    cat "${WORKER_CERT}" | sudo tee "${CERT_FILE}"
  fi
done

sudo shutdown -h now
