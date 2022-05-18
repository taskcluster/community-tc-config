#!/usr/bin/env bash

set -eu
set -o pipefail

function tc_admin {


  ################################################
  # this is temporarily in here while i work out what is needed, then it will be moved into docker image itself...
  apt update
  apt install -y python3-pip python3.8-venv
  pip install --upgrade pip
  python3 -m venv tc-admin-venv
  pip3 install pytest
  pip3 install --upgrade pip
  ################################################


  source tc-admin-venv/bin/activate
  export TEMP_DIR="$(mktemp -d -t password-store.XXXXXXXXXX)"
  export PASSWORD_STORE_DIR="${TEMP_DIR}/.password-store"
  cd "${TEMP_DIR}"
  git clone https://github.com/mozilla/community-tc-config
  cd community-tc-config
  pip3 install -e .
  which tc-admin
  git clone ssh://gitolite3@git-internal.mozilla.org/taskcluster/secrets.git "${PASSWORD_STORE_DIR}"
  export TASKCLUSTER_ROOT_URL='https://community-tc.services.mozilla.com'
  export TASKCLUSTER_CLIENT_ID='static/taskcluster/root'
  export TASKCLUSTER_ACCESS_TOKEN="$(pass show community-tc/root | head -n 1)"
  unset TASKCLUSTER_CERTIFICATE
  tc-admin diff || true
  tc-admin diff --ids-only || true
  echo
  done=false
  while true; do
    read -p "Apply changes (yes/no)? " choice
    case "${choice}" in
      yes)
        echo
        echo 'Applying!'
        echo
        tc-admin apply
        break
        ;;
      no)
        echo "Ok, ok, 🐥."
        break
        ;;
      *)
        echo "Invalid response: '${choice}'. Please answer 'yes' or 'no'."
        ;;
    esac
  done
  cd
  rm -rf "${TEMP_DIR}"
}

################## Entry point ##################

cd "$(dirname "${0}")"

if [ "${1-}" == "native" ]; then
  tc_admin
else
  TAG="$(cat docker/TAG)"
  docker run \
    --rm \
    -ti \
    -v "$(pwd):/community-tc-config" \
    -v ~/.config:/root/.config \
    -v ~/.gitconfig:/root/.gitconfig \
    -v ~/.gnupg:/root/.gnupg \
    -v ~/.ssh:/root/.ssh \
    "${TAG}" \
    /community-tc-config/run-tc-admin.sh native
fi
