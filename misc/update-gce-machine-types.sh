#!/bin/bash -eu

# This script is used to populate the /config/gce-machine-type-offerings.json
# file. The generated file lists which machine types are available per GCP
# zone.
#
# This data is reasonably static, and a little time consuming to generate, and
# therefore is not generated every time tc-admin is run.
#
# Rerun this script with suitable GCP credentials if get an email from Worker
# Manager saying that a GCE machine type isn't available in the request zone.
#
# You will need the gcloud CLI in your PATH.

cd "$(dirname "${0}")"

gcloud compute machine-types list --format='json(name,zone)' > "../config/gce-machine-type-offerings.json" --sort-by 'zone,name'
