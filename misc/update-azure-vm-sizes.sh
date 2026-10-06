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

# `az vm list-skus --location` fetches the SKUs of every location and filters
# client side, so each call is slow and CPU heavy. Instead query the Resource
# SKUs API directly with a server-side location filter, so that each location
# is a small request, and fetch the locations in parallel. The query matches
# the default (no --all) filtering of `az vm list-skus`, which excludes SKUs
# that are not available to the subscription in the location.
function list_vm_sizes {
    local output_dir="${1}"
    local location="${2}"
    az rest --method get \
        --url "https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location eq '${location}'" \
        --query "sort(value[?resourceType=='virtualMachines' && !(restrictions[?reasonCode=='NotAvailableForSubscription' && type=='Location'])].name)" \
        --output json > "${output_dir}/${location}.json"
}
export -f list_vm_sizes

az account list-locations --query="[].name" --output tsv | sort -u | \
xargs -I {} -P "$parallel_processes" bash -c 'list_vm_sizes "$0" "$1"' "$output_dir" {}
