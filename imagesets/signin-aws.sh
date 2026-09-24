#!/usr/bin/env bash

set -eu
set -o pipefail
export SHELLOPTS

# This script expects AWS credentials:
#   SIGNIN_AWS_ACCESS_KEY_ID
#   SIGNIN_AWS_SECRET_ACCESS_KEY
# Or it will use the credentials set up with `aws configure` if those are not set.
#
# It optionally epects the TOTP entry name in your yubikey
#   SIGNIN_AWS_YUBIKEY_OATH_NAME
# Put these environment variables into your .bashrc.local (or .bashrc, if you
# don't sync dot-files). In your .bashrc you'll also want:
#   signin-aws() {
#       eval `signin-aws.sh "${@}"`
#   }
# Then put this script in your PATH as 'signin-aws.sh', and you should be able to
# sign-in by typing 'signin-aws' in your shell.
#
# Note: if using a yubikey nano, you'll probably want touch-required on your
#       TOTP generator. That should also work with this script.

# reset any existing credentials
unset AWS_SESSION_TOKEN
unset AWS_SECRET_ACCESS_KEY
unset AWS_ACCESS_KEY_ID

# Expiration time of login session (in seconds)
DURATION="86400" # 24 hours

# Re-export AWS credentials for use in this script, if set
if [ -n "${SIGNIN_AWS_ACCESS_KEY_ID-}" ]; then
  export AWS_ACCESS_KEY_ID="${SIGNIN_AWS_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${SIGNIN_AWS_SECRET_ACCESS_KEY}"
fi

# Identify the IAM user and AWS account, so the user knows which MFA token to
# provide. The account alias can't be queried without MFA, so callers may set
# SIGNIN_AWS_ACCOUNT_NAME to give it a friendly name.
read AWS_ACCOUNT_ID IAM_USER_ARN < <(aws sts get-caller-identity --query '[Account,Arn]' --output text)
ACCOUNT_DESCRIPTION="${AWS_ACCOUNT_ID}"
if [ -n "${SIGNIN_AWS_ACCOUNT_NAME-}" ]; then
  ACCOUNT_DESCRIPTION="${SIGNIN_AWS_ACCOUNT_NAME} (${AWS_ACCOUNT_ID})"
fi

SERIAL_NUMBER="$(aws iam list-mfa-devices --query 'MFADevices[0].SerialNumber' --output text)"
if [ -z "${SERIAL_NUMBER}" ] || [ "${SERIAL_NUMBER}" == "None" ]; then
  (echo >&2 "Could not list MFA devices for ${IAM_USER_ARN}")
  exit 64
fi

# Attempt to get token from yubikey
TOKEN=''
if [ -n "${SIGNIN_AWS_YUBIKEY_OATH_NAME-}" ]; then
  killall -q scdaemon
  TOKEN="$(yubioath-cli show "${SIGNIN_AWS_YUBIKEY_OATH_NAME}" | rev | cut -b -6 | rev)"
  if [ ! $? -eq 0 ]; then
    TOKEN=''
  fi
fi

# Ask user for token
if [ -z "${TOKEN}" ]; then
  (echo >&2 -n "Enter MFA token for IAM user ${IAM_USER_ARN##*/} in AWS account ${ACCOUNT_DESCRIPTION} (MFA device ${SERIAL_NUMBER}): ")
  read TOKEN
fi

(echo >&2 "Fetching temporary credentials")
aws sts get-session-token --serial-number "${SERIAL_NUMBER}" --token-code "${TOKEN}" --duration-seconds "${DURATION}" --query 'Credentials.{A:AccessKeyId,B:SecretAccessKey,C:SessionToken}' --output text | while read AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
  # Print result as importable for eval
  echo "export AWS_ACCESS_KEY_ID='${AWS_ACCESS_KEY_ID}'"
  echo "export AWS_SECRET_ACCESS_KEY='${AWS_SECRET_ACCESS_KEY}'"
  echo "export AWS_SESSION_TOKEN='${AWS_SESSION_TOKEN}'"
done
