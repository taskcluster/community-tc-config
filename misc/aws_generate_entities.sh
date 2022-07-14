#!/usr/bin/env bash

set -eu
set -o pipefail

cd "$(dirname "${0}")"

./aws-create-instance-profile.sh \
  aws_ec2_generic_trust_policy.json \
  aws_s3_amd_driver_access_policy.json \
  EC2STSAssumeRole \
  S3ReadAMDWindows \
  AMDDriverS3Access
