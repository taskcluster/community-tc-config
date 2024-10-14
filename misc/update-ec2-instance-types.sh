#!/bin/bash -eu

# This script is used to populate the /config/ec2-instance-type-offerings
# directory. The generated files list which instance types are available per
# AWS availability zone.
#
# This data is reasonably static, and a little time consuming to generate, and
# therefore is not generated every time tc-admin is run.
#
# Rerun this script with suitable AWS credentials if get an email from Worker
# Manager with an error like this:
#
#   Error calling AWS API: Your requested instance type (xxx.yyy) is not
#   supported in your requested Availability Zone (zzz).
#
# You will need the aws CLI in your PATH.

cd "$(dirname "${0}")"

rm -f ../config/ec2-instance-type-offerings/*.json
aws ec2 describe-regions --no-paginate --query 'Regions[*].[RegionName]' --output text | while read region; do
  aws --region "${region}" ec2 describe-availability-zones --no-paginate --filters "Name=region-name,Values=${region}" --query 'AvailabilityZones[*].[ZoneName]' --output text | while read availability_zone; do
    aws --region "${region}" ec2 describe-instance-type-offerings --region "${region}" --no-paginate --query 'sort(InstanceTypeOfferings[*].InstanceType)' --location-type availability-zone --filters Name=location,Values="${availability_zone}" > "../config/ec2-instance-type-offerings/${availability_zone}.json"
  done
done
