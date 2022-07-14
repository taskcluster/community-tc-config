#! /bin/bash

set -e

if [ $# -lt 5 ]; then
  echo "Create an IAM instance profile and apply it to a role"
  echo
  echo "Syntax: ${0} <aws_trust_policy> <aws_access_policy> <role_name> <policy_name> <profile_name>"
  echo "<aws_trust_policy>    Path to the aws_trust_policy"
  echo "<aws_access_policy>   Path to the aws_access_policy"
  echo "<role_name>           Role name"
  echo "<policy_name>         Policy name"
  echo "<profile_name>        Profile name"
  exit 1
fi

aws iam create-role --role-name "${3}" --assume-role-policy-document "file://${1}"
aws iam put-role-policy --role-name "${3}" --policy-name "${4}" --policy-document "file://${2}"
aws iam create-instance-profile --instance-profile-name "${5}"
aws iam add-role-to-instance-profile --instance-profile-name "${5}" --role-name "${3}"
