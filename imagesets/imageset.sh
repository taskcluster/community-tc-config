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
# stdin isn't passed to the command, unless MAC_SSH_STDIN=true.
function mac-ssh {
  local host="${1}"
  shift
  local pass_entry="mdc1/generic-worker-ci/${host%%.*}"
  local askpass
  local status=0
  local ssh_options=(-o ConnectTimeout=10 -o NumberOfPasswordPrompts=1)
  "${MAC_SSH_STDIN:-false}" || ssh_options+=(-n)
  askpass="$(mktemp -t mac-askpass.XXXXXXXXXX)"
  printf '#!/bin/sh\npass "%s" | tail -1\n' "${pass_entry}" > "${askpass}"
  chmod 700 "${askpass}"
  SSH_ASKPASS="${askpass}" SSH_ASKPASS_REQUIRE=force ssh "${ssh_options[@]}" "administrator@${host}" "$@" || status=$?
  rm -f "${askpass}"
  return "${status}"
}

# Files in misc/mac that are installed on the macOS workers, before updating
# them, as <file>:<path on the worker>:<mode>. They are only maintained in this
# repository, so that the workers don't drift from it.
MAC_FILES=(
  update.sh:/var/root/update.sh:755
  run-generic-worker.sh:/usr/local/bin/run-generic-worker.sh:755
  com.mozilla.genericworker.plist:/Library/LaunchDaemons/com.mozilla.genericworker.plist:644
  runner.yml:/etc/generic-worker/runner.yml:600
)

# Install MAC_FILES on a macOS worker, with a script that runs on the worker as
# root. In runner.yml, @WORKER_ID@ is replaced with the worker's hostname,
# @PUBLIC_IP@ with its public IP address, and @STATIC_SECRET@ with the
# staticSecret in its existing runner.yml (so the secret never leaves the
# worker). Each file is written to a new file that is renamed
# into place, so that a running script isn't modified.
function install-mac-files {
  local host="${1}"
  local entry file dest mode
  {
    cat << 'EOF'
set -eu
# Not readable by others while being written, as runner.yml has a secret
umask 077
# Replace the placeholders, other than in comments (which mention them), with
# string operations, as the secret may contain any character
function replace_placeholders {
  awk '
    function replace(placeholder, value) {
      while ((i = index($0, placeholder)) > 0) {
        $0 = substr($0, 1, i - 1) value substr($0, i + length(placeholder))
      }
    }
    !/^ *#/ {
      replace("@WORKER_ID@", ENVIRON["WORKER_ID"])
      replace("@PUBLIC_IP@", ENVIRON["PUBLIC_IP"])
      replace("@STATIC_SECRET@", ENVIRON["STATIC_SECRET"])
    }
    { print }
  '
}
STATIC_SECRET="$(sed -n 's/^  staticSecret: //p' /etc/generic-worker/runner.yml)"
[ -n "${STATIC_SECRET}" ] || { echo "No staticSecret in /etc/generic-worker/runner.yml" >&2; exit 1; }
export STATIC_SECRET
# If the public IP address can't be determined, keep the existing one
PUBLIC_IP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com || true)"
if ! [[ "${PUBLIC_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  PUBLIC_IP="$(sed -n 's/^  publicIP: "\(.*\)"$/\1/p' /etc/generic-worker/runner.yml)"
  echo "WARNING: Couldn't determine the public IP address; keeping ${PUBLIC_IP}" >&2
fi
export PUBLIC_IP
EOF
    echo "export WORKER_ID='${host%%.*}'"
    for entry in "${MAC_FILES[@]}"; do
      IFS=: read -r file dest mode <<< "${entry}"
      echo "base64 -d << 'END_OF_BASE64' | replace_placeholders > '${dest}.new'"
      base64 < "${IMAGESETS_DIR}/../misc/mac/${file}"
      echo 'END_OF_BASE64'
      echo "chown root:wheel '${dest}.new'"
      echo "chmod ${mode} '${dest}.new'"
      echo "if cmp -s '${dest}.new' '${dest}'; then rm '${dest}.new'; echo '${host%%.*}: ${dest} is up to date'; else mv -f '${dest}.new' '${dest}'; echo '${host%%.*}: updated ${dest}'; fi"
    done
  } | MAC_SSH_STDIN=true mac-ssh "${host}" sudo -n bash -s
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
  # Bump worker-images' TCEng configs to the latest Taskcluster release (via a PR
  # that must be merged) before building
  : ${UPDATE_TASKCLUSTER_VERSION:=true}
  export UPDATE_TASKCLUSTER_VERSION
  # Open a PR to have fxci's worker pools use the new images too
  : ${UPDATE_FXCI_IMAGES:=true}
  : ${DEPLOY_MACS:=true}

  : ${LOGIN_AWS:=true}
  : ${LOGIN_AZURE:=true}

  : ${UPDATE_GCLOUD:=true}
  : ${UPDATE_OFFERINGS:=true}

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

  if "${BUILD_IMAGES}"; then
    GITHUB_TOKEN="$(gh auth token)"
    export GITHUB_TOKEN
    # The worker-images PR needs someone to review and merge it, so open it
    # before anything else. Only building the images waits for it to be merged
    # (in rel-sre-imagesets.py below); the steps in between don't depend on it.
    if "${UPDATE_TASKCLUSTER_VERSION}"; then
      python3 imagesets/rel-sre-imagesets.py --open-bump-pr
    fi
  fi

  if "${UPDATE_OFFERINGS}"; then
    echo "Updating EC2 instance types..."
    misc/update-ec2-instance-types.sh
    git add 'config/ec2-instance-type-offerings'
    git commit -m "Ran script misc/update-ec2-instance-types.sh" || true

    echo "Updating Azure VM sizes..."
    misc/update-azure-vm-sizes.sh
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
      install-mac-files "${HOST}"
      mac-ssh "${HOST}" sudo -n bash -c /var/root/update.sh
    done
  fi


  if "${BUILD_IMAGES}"; then
    python3 imagesets/rel-sre-imagesets.py
    git add config/imagesets.yml
    git commit -m "Built new machine images"
    retry git -c pull.rebase=true pull "${OFFICIAL_GIT_REPO}" main
    retry git push "${OFFICIAL_GIT_REPO}" "+HEAD:refs/heads/main"
  fi

  if "${DEPLOY_IMAGES}"; then
    # Images must exist before tc-admin points worker pools at them
    python3 imagesets/copy-azure-images.py
    retry tc-admin apply
  fi

  if "${BUILD_IMAGES}"; then
    python3 imagesets/rel-sre-imagesets.py --log-images
    # fxci's config can only be changed with a reviewed PR
    if "${UPDATE_FXCI_IMAGES}"; then
      python3 imagesets/rel-sre-imagesets.py --open-fxci-pr
    fi
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
