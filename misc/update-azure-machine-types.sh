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

rm '../config/azure-machine-type-offerings.json'
locations=$(az account list-locations --query="[].name" --output tsv)

list="["
for location in $locations; do
  types=$(az vm list-sizes --location $location --query="[].name" --output tsv 2>/dev/null || true)

  for type in $types; do
    list="$list{\"name\": \"$type\", \"zone\": \"$location\"},"
  done
done

# Remove the last comma and add the closing bracket
list="${list%?}"
list="$list]"

tempPath=$(mktemp)
echo "$list" > $tempPath
jq '.' $tempPath > ../config/azure-machine-type-offerings.json
rm $tempPath
