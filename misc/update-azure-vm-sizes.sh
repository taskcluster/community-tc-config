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
# You will need the az CLI, curl and python3 in your PATH.

cd "$(dirname "${0}")"

output_dir="../config/azure-vm-size-offerings"

skus="$(mktemp -t azure-skus.XXXXXXXXXX)"
trap 'rm -f "${skus}"' EXIT

# Fetch the SKUs of all locations in a single request, and split them per
# location below. This is as quick as a request per location in parallel, and
# there is only one request that can hang, which curl times out and retries.
# `az vm list-skus` is avoided as it is very slow to process the response.
subscription_id="$(az account show --query id --output tsv)"
access_token="$(az account get-access-token --query accessToken --output tsv)"
# The token is passed on stdin, rather than as an argument visible to other processes.
echo "Authorization: Bearer ${access_token}" | curl --fail --silent --show-error --compressed \
    --connect-timeout 30 --max-time 600 --retry 5 --retry-all-errors \
    --header @- --output "${skus}" \
    "https://management.azure.com/subscriptions/${subscription_id}/providers/Microsoft.Compute/skus?api-version=2021-07-01"

locations="$(az account list-locations --query="[].name" --output tsv | sort -u)"

mkdir -p "$output_dir"
rm -f "$output_dir"/*.json

# Matches the default (no --all) filtering of `az vm list-skus`, which excludes
# SKUs that are not available to the subscription in the location.
python3 -I - "${skus}" "${output_dir}" ${locations} << 'EOF'
import json
import sys

skus_file, output_dir, *locations = sys.argv[1:]
with open(skus_file) as f:
    response = json.load(f)
if response.get("nextLink"):
    sys.exit("Resource SKUs API response is paged, which this script doesn't handle")

vm_sizes = {location: set() for location in locations}
for sku in response["value"]:
    if sku["resourceType"] != "virtualMachines":
        continue
    if any(
        r.get("reasonCode") == "NotAvailableForSubscription" and r.get("type") == "Location"
        for r in sku.get("restrictions") or []
    ):
        continue
    for location in sku["locations"]:
        if location.lower() in vm_sizes:
            vm_sizes[location.lower()].add(sku["name"])

for location, names in vm_sizes.items():
    with open(f"{output_dir}/{location}.json", "w") as f:
        json.dump(sorted(names), f, indent=2)
        f.write("\n")
EOF
