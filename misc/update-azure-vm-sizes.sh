#!/bin/bash -eu

# This script is used to populate the /config/azure-vm-size-offerings
# directory. The generated file lists which machine types are available per
# Azure location.
#
# This data is reasonably static, and a little time consuming to generate, and
# therefore is not generated every time tc-admin is run.
#
# Rerun this script with suitable Azure credentials if get an email from Worker
# Manager saying that an Azure machine type isn't available in the requested
# location.
#
# You will need the az CLI in your PATH.

cd "$(dirname "${0}")"

output_dir="../config/azure-vm-size-offerings"
mkdir -p "$output_dir"
rm -f "$output_dir"/*.json

if [ $# -eq 0 ]; then
    parallel_processes=10
else
    parallel_processes=$1
fi

az account list-locations --query="[].name" --output tsv | sort -u | \
xargs -I {} -P "$parallel_processes" bash -c 'az vm list-skus --location "$1" --resource-type virtualMachines --query="sort([].name)" --output json 2> /dev/null > "$0/$1.json"' "$output_dir" {}
