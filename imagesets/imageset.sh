#!/usr/bin/env bash

set -eu
set -o pipefail

function retry {
  set +e
  local n=0
  # 2^10 seconds is plenty
  local max=10
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command $@ failed" >&2
        sleep_time=$((2 ** n))
        echo "Sleeping $sleep_time seconds..." >&2
        sleep $sleep_time
        echo "Attempt $n/$max:" >&2
      else
        echo "Failed after $n attempts." >&2
        return 67
      fi
    }
  done
  set -e
}

# Run a command on a macOS worker as administrator. The administrator password
# (from pass) is used for ssh authentication if key authentication fails.
function mac-ssh {
  local host="${1}"
  shift
  local pass_entry="mdc1/generic-worker-ci/${host%%.*}"
  local askpass
  local status=0
  askpass="$(mktemp -t mac-askpass.XXXXXXXXXX)"
  printf '#!/bin/sh\npass "%s" | tail -1\n' "${pass_entry}" > "${askpass}"
  chmod 700 "${askpass}"
  SSH_ASKPASS="${askpass}" SSH_ASKPASS_REQUIRE=force ssh -n -o ConnectTimeout=10 -o NumberOfPasswordPrompts=1 "administrator@${host}" "$@" || status=$?
  rm -f "${askpass}"
  return "${status}"
}

# Fail early if any macOS worker can't be reached over ssh, or administrator
# doesn't have passwordless sudo, rather than discovering it after all the
# other (lengthy) steps have run.
function check-mac-connectivity {
  local host
  local output
  local failed=false
  for host in "$@"; do
    if ! output="$(mac-ssh "${host}" sudo -n echo hello 2>&1)" || [ "${output}" != "hello" ]; then
      echo "Cannot ssh to administrator@${host} and run sudo: ${output}" >&2
      if [[ "${output}" == *"Could not resolve hostname"* ]]; then
        echo "Updating macOS workers (DEPLOY_MACS=true) requires connecting to the Mozilla corporate VPN." >&2
      fi
      failed=true
    fi
  done
  if "${failed}"; then
    echo "Fix the above, or rerun with DEPLOY_MACS=false to skip the macOS workers." >&2
    return 1
  fi
}

############### Deploy all image sets ###############

function all-in-parallel {
  : ${BUILD_IMAGES:=true}

  : ${DEPLOY_IMAGES:=true}
  : ${DEPLOY_MACS:=true}

  : ${LOGIN_AWS:=true}
  : ${LOGIN_AZURE:=true}

  : ${UPDATE_GCLOUD:=true}
  : ${UPDATE_OFFERINGS:=true}
  : ${AZURE_VM_SIZES_PARALLEL_PROCESSES:=10}

  # TODO: fetch these hosts automatically
  local MAC_HOSTS=(
    macmini-m4-126.test.releng.mdc1.mozilla.com
    macmini-m4-127.test.releng.mdc1.mozilla.com
  )

  if "${DEPLOY_MACS}"; then
    check-mac-connectivity "${MAC_HOSTS[@]}"
  fi

  export GCP_PROJECT=taskcluster-imaging
  export AZURE_IMAGE_RESOURCE_GROUP=rg-tc-eng-images
  # Taskcluster Engineering DevTest Subscription
  export AZURE_SUBSCRIPTION_ID=8a205152-b25a-417f-a676-80465535a6c9

  export TASKCLUSTER_CLIENT_ID='static/taskcluster/root'
  export TASKCLUSTER_ROOT_URL='https://community-tc.services.mozilla.com'
  unset TASKCLUSTER_CERTIFICATE

  if "${LOGIN_AZURE}"; then
    retry az login --tenant mozilla.com --subscription "${AZURE_SUBSCRIPTION_ID}"
  fi

  if "${UPDATE_GCLOUD}"; then
    retry gcloud components update -q
  fi
  retry gcloud auth login

  PREP_DIR="$(mktemp -t deploy-worker-pools.XXXXXXXXXX -d)"
  cd "${PREP_DIR}"

  echo
  echo "Preparing in directory ${PREP_DIR}..."
  echo

  mkdir tc-admin

  cd tc-admin
  python3 -m venv tc-admin-venv
  source tc-admin-venv/bin/activate
  pip3 install pytest
  pip3 install --upgrade pip

  cd "${IMAGESETS_DIR}/.."

  pip3 install -e .
  which tc-admin
  export TASKCLUSTER_ACCESS_TOKEN="$(pass ls community-tc/root | head -1)"

  if "${LOGIN_AWS}"; then
    eval $(SIGNIN_AWS_ACCOUNT_NAME=moz-fx-tc-community-workers imagesets/signin-aws.sh)
  fi

  if "${UPDATE_OFFERINGS}"; then
    echo "Updating EC2 instance types..."
    misc/update-ec2-instance-types.sh
    git add 'config/ec2-instance-type-offerings'
    git commit -m "Ran script misc/update-ec2-instance-types.sh" || true

    echo "Updating Azure VM sizes..."
    misc/update-azure-vm-sizes.sh "${AZURE_VM_SIZES_PARALLEL_PROCESSES}"
    git add 'config/azure-vm-size-offerings'
    git commit -m "Ran script misc/update-azure-vm-sizes.sh" || true

    echo "Updating GCE machine types..."
    misc/update-gce-machine-types.sh
    git add 'config/gce-machine-type-offerings.json'
    git commit -m "Ran script misc/update-gce-machine-types.sh" || true

    retry git push "${OFFICIAL_GIT_REPO}"
    retry tc-admin apply
  fi

  #######################################################################################
  ######## Comment out image sets / macOS workers that don't need to be updated! ########
  #######################################################################################


  ##################################
  ###### Update macOS workers ######
  ##################################
  #
  # ssh connectivity is checked at the start of the script.
  # Remeber to vnc as administrator onto macs before running this script, to avoid ssh connection problems!

  # TODO: report if macs need to be logged into first with vnc
  if "${DEPLOY_MACS}"; then
    for HOST in "${MAC_HOSTS[@]}"; do
      mac-ssh "${HOST}" sudo -n bash -c /var/root/update.sh
    done
  fi


  if "${BUILD_IMAGES}"; then
    export GITHUB_TOKEN=$(gh auth token)
    python3 imagesets/rel-sre-imagesets.py
    git add config/imagesets.yml
    git commit -m "Built new machine images"
    retry git -c pull.rebase=true pull "${OFFICIAL_GIT_REPO}" main
    retry git push "${OFFICIAL_GIT_REPO}" "+HEAD:refs/heads/main"
  fi

  if "${DEPLOY_IMAGES}"; then
    retry tc-admin apply
  fi

  echo
  echo "Deleting preparation directory: ${PREP_DIR}..."
  echo
  cd
  rm -rf "${PREP_DIR}"
  echo "All done!"
}

################## Entry point ##################

cd "$(dirname "${0}")"

IMAGESETS_DIR="$(pwd)"

export OFFICIAL_GIT_REPO='git@github.com:taskcluster/community-tc-config'

if [ "${1-}" == "all" ]; then
  all-in-parallel
  exit 0
fi
