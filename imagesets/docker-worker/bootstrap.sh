#!/bin/bash

set -exv
exec &> /var/log/bootstrap.log

WORKER_CERT="$(dirname $(realpath $0))/worker-cert.pem"

for CERT_FILE in /etc/star_taskcluster-worker_net.crt /etc/taskcluster/secrets/worker_livelog_tls_cert; do
  if [ -f "${CERT_FILE}" ]; then
    sudo cp "${WORKER_CERT}" "${CERT_FILE}"
  fi
done

sudo shutdown -h now
