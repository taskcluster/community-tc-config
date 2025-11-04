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

function log {
  if [ -n "${BACKGROUND_COLOUR-}" ] && [ -n "${FOREGROUND_COLOUR-}" ] && [ -n "${CLOUD-}" ] && [ -n "${IMAGE_SET-}" ] && [ -n "${REGION-}" ]; then
    echo -e "\x1B[48;5;${BACKGROUND_COLOUR}m\x1B[38;5;${FOREGROUND_COLOUR}m$(basename "${0}"): $(date -u +"%Y-%m-%dT%H:%M:%SZ"): ${CLOUD}: ${IMAGE_SET}: ${REGION}: ${@}\x1B[K\x1B[0m"
  else
    echo -e "\x1B[48;5;123m\x1B[38;5;0m$(basename "${0}"): $(date): ${@}\x1B[K\x1B[0m"
  fi
}

function log-iff-fails {
  export TEMP_FILE="$(mktemp -t log-iff-fails.XXXXXXXXXX)"
  "${@}" > "${TEMP_FILE}" 2>&1
  local return_code=$?
  if [ "${return_code}" != 0 ]; then
    cat "${TEMP_FILE}"
  fi
  rm "${TEMP_FILE}"
  return "${return_code}"
}

############### Deploy all image sets ###############

function all-in-parallel {
  : ${BUILD_IMAGES:=true}
  : ${BUILD_STAGING_IMAGES:=false}
  : ${DELETE_OLD_RGS:=true}

  : ${DEPLOY_IMAGES:=true}
  : ${DEPLOY_MACS:=true}

  : ${LOGIN_AWS:=true}
  : ${LOGIN_AZURE:=true}

  : ${UPDATE_GCLOUD:=true}
  : ${UPDATE_OFFERINGS:=true}
  : ${AZURE_VM_SIZES_PARALLEL_PROCESSES:=10}
  : ${UPDATE_TASKCLUSTER_VERSION:=true}

  : ${USE_LATEST_TASKCLUSTER_VERSION:=true}

  export GCP_PROJECT=community-tc-workers
  export AZURE_IMAGE_RESOURCE_GROUP=rg-tc-eng-images

  export TASKCLUSTER_CLIENT_ID='static/taskcluster/root'
  export TASKCLUSTER_ROOT_URL='https://community-tc.services.mozilla.com'
  unset TASKCLUSTER_CERTIFICATE

  if "${LOGIN_AZURE}"; then
    retry az login
  fi

  if "${DELETE_OLD_RGS}"; then
    for rg in $(az group list --query "[?starts_with(name, 'imageset-')].name" -o tsv); do
      echo "Deleting old resource group ${rg}..."
      az group delete --name $rg --yes --no-wait
    done
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

  if "${USE_LATEST_TASKCLUSTER_VERSION}"; then
    VERSION="$(retry curl https://api.github.com/repos/taskcluster/taskcluster/releases/latest 2>/dev/null | jq -r .tag_name)"
    if [ -z "${VERSION}" ]; then
      echo "Cannot retrieve latest taskcluster version" >&2
      return 64
    fi
  fi
  if "${UPDATE_TASKCLUSTER_VERSION}" && [ -z "${VERSION}" ]; then
    echo "No taskcluster version specified" >&2
    return 75
  fi

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
    eval $(imagesets/signin-aws.sh)
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

  if "${UPDATE_TASKCLUSTER_VERSION}"; then
    cd imagesets
    git ls-files | grep -F 'bootstrap.' | while read file; do
      cat "${file}" > "${file}.bak"
      cat "${file}.bak" | sed 's/^ *setenv TASKCLUSTER_VERSION .*/setenv TASKCLUSTER_VERSION '"${VERSION}"'/' \
        | sed 's/^ *TASKCLUSTER_VERSION=.*/TASKCLUSTER_VERSION='"'${VERSION}'"'/' \
        | sed 's/^ *\$TASKCLUSTER_VERSION *=.*/$TASKCLUSTER_VERSION = "'"${VERSION}"'"/' \
        > "${file}"
      rm "${file}.bak"
      git add "${file}"
    done
    git commit -m "chore: bump to TC ${VERSION}" || true
    retry git push "${OFFICIAL_GIT_REPO}"
    cd ..
  fi

  #######################################################################################
  ######## Comment out image sets / macOS workers that don't need to be updated! ########
  #######################################################################################


  ##################################
  ###### Update macOS workers ######
  ##################################
  #
  # Remember to connect to the mozilla VPN before running this script in order to access the mac minis!
  # Remeber to vnc as administrator onto macs before running this script, to avoid ssh connection problems!

  # TODO: fetch these IPs automatically, and report if they need to be logged into first with vnc
  if "${DEPLOY_MACS}"; then
    for HOST in macmini-m4-126 macmini-m4-127; do
      pass "mdc1/generic-worker-ci/${HOST}" | tail -1 | ssh "administrator@${HOST}.test.releng.mdc1.mozilla.com" sudo -S "bash" -c /var/root/update.sh
    done
  fi


  if "${BUILD_IMAGES}"; then
    if "${DELETE_OLD_RGS}"; then
      for rg in $(az group list --query "[?starts_with(name, 'imageset-')].name" -o tsv); do
        echo "Deleting old resource group ${rg}..."
        az group delete --name $rg --yes --no-wait
      done
    fi
    export GITHUB_TOKEN=$(gh auth token)
    python3 imagesets/rel-sre-imagesets.py
    git add config/imagesets.yml
    git commit -m "Built new Azure machine images"
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
