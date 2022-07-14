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

echo "Creating role ${3} using trust policy located at ${1}."
aws iam create-role --role-name "${3}" --assume-role-policy-document "file://${1}" 2> /dev/null
echo "Applying access policy located at ${2} to role ${3}."
aws iam put-role-policy --role-name "${3}" --policy-name "${4}" --policy-document "file://${2}"
echo "Creating instance profile using name ${5}."
aws iam create-instance-profile --instance-profile-name "${5}" 2> /dev/null
echo "Adding role ${3} to instance profile ${5}."
aws iam add-role-to-instance-profile --instance-profile-name "${5}" --role-name "${3}"
