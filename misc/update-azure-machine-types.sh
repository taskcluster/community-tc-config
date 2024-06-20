#!/bin/bash -eu

# This script is used to populate the /config/azure-machine-type-offerings.json
# file. The generated file lists which machine types are available per Azure
# location.
#
# This data is reasonably static, and a little time consuming to generate, and
# therefore is not generated every time tc-admin is run.
#
# Rerun this script with suitable Azure credentials if get an email from Worker
# Manager saying that an Azure machine type isn't available in the requested location.
#
# You will need the az and jq CLIs in your PATH.

cd "$(dirname "${0}")"

rm -f '../config/azure-machine-type-offerings.json'
az account list-locations --query="[].name" --output tsv | sort -u | while read location; do
  az vm list-sizes --location $location --query="[].name" --output tsv 2> /dev/null | sort -u | while read type; do
    echo -n "{\"name\": \"$type\", \"zone\": \"$location\"},"
  done
done | sed 's/\(.*\)./[\1]/' | jq '.' > ../config/azure-machine-type-offerings.json
