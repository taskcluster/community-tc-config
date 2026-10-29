#!/usr/bin/env bash

set -eu
set -o pipefail

function retry {
  local n=0
  # 2^10 seconds is plenty
  local max=10
  until "$@"; do
    if [[ $n -ge $max ]]; then
      echo "Failed after $n attempts." >&2
      return 67
    fi
    n=$((n + 1))
    echo "Command $@ failed" >&2
    sleep_time=$((2 ** n))
    echo "Sleeping $sleep_time seconds..." >&2
    sleep $sleep_time
    echo "Attempt $n/$max:" >&2
  done
}

function install-hint {
  local tool="${1}"
  local package
  if [ "$(uname)" == Darwin ]; then
    case "${tool}" in
      aws) echo "brew install awscli" ;;
      az) echo "brew install --cask azure-cli" ;;
      gcloud) echo "brew install --cask gcloud-cli" ;;
      gh | git | pass) echo "brew install ${tool}" ;;
      gpg) echo "brew install gnupg" ;;
      python3) echo "brew install python" ;;
      ssh) echo "brew install openssh" ;;
      *) echo "it is part of macOS: check your PATH" ;;
    esac
    return
  fi
  case "${tool}" in
    aws) echo "see https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html (version 2 is needed)"; return ;;
    az) echo "see https://learn.microsoft.com/cli/azure/install-azure-cli-linux"; return ;;
    gcloud) echo "see https://cloud.google.com/sdk/docs/install"; return ;;
    gh) echo "see https://github.com/cli/cli/blob/trunk/docs/install_linux.md"; return ;;
  esac
  if command -v apt-get > /dev/null; then
    case "${tool}" in
      curl | git | pass | python3 | tar) package="${tool}" ;;
      gpg) package=gnupg ;;
      ssh) package=openssh-client ;;
      *) package=coreutils ;;
    esac
    echo "sudo apt-get install ${package}"
  elif command -v dnf > /dev/null; then
    case "${tool}" in
      curl | git | pass | python3 | tar) package="${tool}" ;;
      gpg) package=gnupg2 ;;
      ssh) package=openssh-clients ;;
      *) package=coreutils ;;
    esac
    echo "sudo dnf install ${package}"
  else
    echo "install it with your package manager"
  fi
}

function check-required-tools {
  local tools=(az cat chmod dirname env gcloud gh git gpg grep id mkdir mktemp pass paste python3 rm sed sleep tee tr tty uname)
  local tool
  local missing=false
  local version
  if "${DEPLOY_MACS}"; then
    tools+=(base64 seq ssh)
  fi
  if "${UPDATE_OFFERINGS}"; then
    tools+=(aws curl sort)
  fi
  if "${IMAGESET_LOCAL_CHANGES}"; then
    tools+=(tar)
  fi
  for tool in "${tools[@]}"; do
    if ! command -v "${tool}" > /dev/null; then
      echo "Required tool ${tool} not found in PATH. To install it: $(install-hint "${tool}")" >&2
      missing=true
    fi
  done
  if "${missing}"; then
    return 1
  fi
  if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
    echo "Python 3.10 or later is needed, rather than $(python3 --version 2>&1). To install it: $(install-hint python3)" >&2
    return 1
  fi
  if ! python3 -c 'import ensurepip, venv' 2> /dev/null; then
    echo "python3 can't create virtualenvs: install its venv module (e.g. sudo apt-get install python3-venv)." >&2
    return 1
  fi
  if "${UPDATE_OFFERINGS}" && [[ "$(aws --version 2>&1)" != aws-cli/2.* ]]; then
    echo "Version 2 of the AWS CLI is needed, rather than $(aws --version 2>&1). To install it: $(install-hint aws)" >&2
    return 1
  fi
  # For SSH_ASKPASS_REQUIRE
  if "${DEPLOY_MACS}"; then
    version="$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
    if [ -z "${version}" ] || [ "${version% *}" -lt 8 ] || { [ "${version% *}" -eq 8 ] && [ "${version#* }" -lt 4 ]; }; then
      echo "OpenSSH 8.4 or later is needed, rather than $(ssh -V 2>&1). To install it: $(install-hint ssh)" >&2
      return 1
    fi
  fi
  # Read in the user's checkout, for any includeIf in their git configuration
  IMAGESET_GIT_NAME="$(git -C "${IMAGESETS_DIR}" config user.name || true)"
  IMAGESET_GIT_EMAIL="$(git -C "${IMAGESETS_DIR}" config user.email || true)"
  export IMAGESET_GIT_NAME IMAGESET_GIT_EMAIL
  if [ -z "${IMAGESET_GIT_NAME}" ] || [ -z "${IMAGESET_GIT_EMAIL}" ]; then
    echo "Set your name and email for git commits, e.g. with: git config --global user.name 'Your Name'; git config --global user.email you@mozilla.com" >&2
    return 1
  fi
  if [[ "$(gh auth login --help)" != *--insecure-storage* ]]; then
    echo "A newer gh is needed, rather than $(gh --version | head -1). To install it: $(install-hint gh)" >&2
    return 1
  fi
}

function can-open-browser {
  [ -z "${SSH_CONNECTION-}" ] && { [ "$(uname)" == Darwin ] || [ -n "${DISPLAY-}" ] || [ -n "${WAYLAND_DISPLAY-}" ]; }
}

function update-gcloud {
  local log="${PREP_DIR}/gcloud-update.log"
  if gcloud components update -q 2>&1 | tee "${log}"; then
    return 0
  fi
  if [[ "$(tr -s ' \n' ' ' < "${log}")" == *"component manager is disabled"* ]]; then
    echo "gcloud was installed with a package manager: update it with that instead." >&2
    return 0
  fi
  return 1
}

# Run a command on a macOS worker as administrator. stdin isn't passed to the
# command, unless MAC_SSH_STDIN=true.
function mac-ssh {
  local host="${1}"
  shift
  local password_var="MAC_PASSWORD_$(mac-name "${host}")"
  # StrictHostKeyChecking, as SSH_ASKPASS would answer a host key prompt
  local ssh_options=(
    -F /dev/null
    -o ConnectTimeout=10
    -o NumberOfPasswordPrompts=1
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=keyboard-interactive,password
    -o StrictHostKeyChecking=yes
    -o CheckHostIP=no
    -o "UserKnownHostsFile=\"${IMAGESETS_DIR}/mac_known_hosts\""
    -o GlobalKnownHostsFile=/dev/null
    -o UpdateHostKeys=no
  )
  "${MAC_SSH_STDIN:-false}" || ssh_options+=(-n)
  MAC_SSH_PASSWORD="${!password_var}" SSH_ASKPASS="${PREP_DIR}/mac-askpass" SSH_ASKPASS_REQUIRE=force \
    ssh "${ssh_options[@]}" "administrator@${host}" "$@"
}

function mac-name {
  local name="${1%%.*}"
  echo "${name//-/_}"
}

function read-mac-passwords {
  local host
  local entry
  for host in "$@"; do
    entry="$(read-pass "mdc1/generic-worker-ci/${host%%.*}")"
    printf -v "MAC_PASSWORD_$(mac-name "${host}")" '%s' "${entry##*$'\n'}"
  done
  printf '#!/bin/sh\nprintf "%%s\\n" "${MAC_SSH_PASSWORD}"\n' > "${PREP_DIR}/mac-askpass"
  chmod 700 "${PREP_DIR}/mac-askpass"
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

# Workers may be rebooting
MAC_SSH_ATTEMPTS=10
MAC_SSH_RETRY_INTERVAL=30

# Succeeds if ssh output shows an error that retrying won't fix
function mac-ssh-permanent-error {
  [[ "${1}" =~ "Could not resolve hostname"|"Host key verification failed"|"Permission denied" ]]
}

# Retries a command (with the host as its first argument) while ssh can't connect
function retry-mac {
  local host="${2}"
  local attempt
  local status
  local output
  for attempt in $(seq "${MAC_SSH_ATTEMPTS}"); do
    status=0
    "$@" || status=$?
    if [ "${status}" != 255 ] || [ "${attempt}" == "${MAC_SSH_ATTEMPTS}" ]; then
      return "${status}"
    fi
    output="$(mac-ssh "${host}" true 2>&1)" || true
    if mac-ssh-permanent-error "${output}"; then
      echo "ssh to ${host} failed: ${output}" >&2
      return "${status}"
    fi
    echo "Couldn't connect to ${host} (it may be rebooting), retrying in ${MAC_SSH_RETRY_INTERVAL} seconds (attempt ${attempt}/${MAC_SSH_ATTEMPTS} failed)..." >&2
    sleep "${MAC_SSH_RETRY_INTERVAL}"
  done
}

# Fail early if any macOS worker can't be reached over ssh, or administrator
# doesn't have passwordless sudo, rather than discovering it after all the
# other (lengthy) steps have run.
function check-mac-connectivity {
  local host
  local output
  local failed=false
  local attempt
  local status
  for host in "$@"; do
    for attempt in $(seq "${MAC_SSH_ATTEMPTS}"); do
      status=0
      output="$(mac-ssh "${host}" sudo -n echo hello 2>&1)" || status=$?
      if [ "${status}" != 255 ] || [ "${attempt}" == "${MAC_SSH_ATTEMPTS}" ] || mac-ssh-permanent-error "${output}"; then
        break
      fi
      echo "Couldn't connect to ${host} (it may be rebooting), retrying in ${MAC_SSH_RETRY_INTERVAL} seconds (attempt ${attempt}/${MAC_SSH_ATTEMPTS} failed): ${output}" >&2
      sleep "${MAC_SSH_RETRY_INTERVAL}"
    done
    if [ "${status}" != 0 ] || [ "${output}" != "hello" ]; then
      echo "Cannot ssh to administrator@${host} and run sudo: ${output}" >&2
      if [ "${status}" == 255 ] && ! [[ "${output}" =~ "Host key verification failed"|"Permission denied" ]]; then
        echo "Updating macOS workers (DEPLOY_MACS=true) requires connecting to the Mozilla corporate VPN." >&2
      fi
      if [[ "${output}" == *"Host key verification failed"* ]]; then
        echo "The host key of ${host} isn't in ${IMAGESETS_DIR}/mac_known_hosts: if the worker was reinstalled, update it (ssh-keyscan -t ed25519 <host>)." >&2
      fi
      if [[ "${output}" == *"Permission denied"* ]]; then
        echo "The administrator password of ${host} in the password store (mdc1/generic-worker-ci/${host%%.*}) was rejected: it may need updating." >&2
      fi
      failed=true
    fi
  done
  if "${failed}"; then
    echo "Fix the above, or rerun with DEPLOY_MACS=false to skip the macOS workers." >&2
    return 1
  fi
}

# Use our own configuration of the tools, rather than the user's
function isolate-environment {
  local git_name
  local git_email
  local var
  git_name="${IMAGESET_GIT_NAME}"
  git_email="${IMAGESET_GIT_EMAIL}"

  for var in $(compgen -e); do
    case "${var}" in
      CLOUDSDK_PYTHON*) ;;
      GIT_*|GH_*|GITHUB_*|AWS_*|AZURE_*|CLOUDSDK_*|PASSWORD_STORE_*|PIP_*|PYTHON*|VIRTUAL_ENV|TASKCLUSTER_*) unset "${var}" ;;
    esac
  done

  export GIT_CONFIG_GLOBAL="${PREP_DIR}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_TERMINAL_PROMPT=0
  git config --global user.name "${git_name}"
  git config --global user.email "${git_email}"
  git config --global credential.https://github.com.helper '!gh auth git-credential'
  git config --global credential.https://source.developers.google.com.helper '!gcloud auth git-helper --ignore-unknown "$@"'

  export GH_CONFIG_DIR="${PREP_DIR}/gh"
  mkdir "${GH_CONFIG_DIR}"
  printf 'version: 1\ngit_protocol: https\nprompt: disabled\n' > "${GH_CONFIG_DIR}/config.yml"

  export CLOUDSDK_CONFIG="${PREP_DIR}/gcloud"

  export AZURE_CONFIG_DIR="${PREP_DIR}/azure"
  export AZURE_CORE_LOGIN_EXPERIENCE_V2=off

  export AWS_CONFIG_FILE="${PREP_DIR}/aws-config"
  export AWS_SHARED_CREDENTIALS_FILE=/dev/null
  export AWS_PAGER=''

  export PIP_CONFIG_FILE=/dev/null

  # A pager would wait for a key press
  export PAGER=cat GIT_PAGER=cat GH_PAGER=cat
}

function read-pass {
  local entry="${1}"
  if ! pass show "${entry}"; then
    echo "Couldn't decrypt ${entry} from the password store. Check that your gpg key is one that the password store is encrypted to (see ${PASSWORD_STORE_DIR}/.gpg-id), and that gpg can prompt for its passphrase." >&2
    return 1
  fi
}

# Everything that needs a passphrase (gpg, for the password store) runs at the
# start. Afterwards, gpg and ssh keys fail rather than prompt, as a late prompt
# can time out while nobody is watching, and pass only serves the entries in
# PASS_CACHE (read at the start), e.g. for tc-admin's secret values.
function disable-passphrase-prompts {
  local bin="${PREP_DIR}/no-passphrase-prompts"
  local tool
  mkdir "${bin}"
  printf '#!/bin/sh\n[ "$1" = show ] && shift\nif [ $# = 1 ] && [ -f "%s/$1" ]; then exec cat "%s/$1"; fi\necho "imageset.sh: pass is disabled after the start, so that it cannot prompt for a passphrase, and $* was not read then" >&2\nexit 1\n' "${PASS_CACHE}" "${PASS_CACHE}" > "${bin}/pass"
  chmod 755 "${bin}/pass"
  for tool in gpg gpg2 ssh-for-git; do
    printf '#!/bin/sh\necho "imageset.sh: %s is disabled after the start, so that it cannot prompt for a passphrase" >&2\nexit 1\n' "${tool}" > "${bin}/${tool}"
    chmod 755 "${bin}/${tool}"
  done
  export PATH="${bin}:${PATH}"
  export GIT_SSH_COMMAND="${bin}/ssh-for-git"
  unset SSH_AUTH_SOCK
}

# Decrypts a password store entry into PASS_CACHE, for disable-passphrase-prompts
function cache-pass-entry {
  local entry="${1}"
  mkdir -p -m 700 "${PASS_CACHE}/$(dirname "${entry}")"
  (umask 077 && read-pass "${entry}" > "${PASS_CACHE}/${entry}")
}

function clone-password-store {
  export PASSWORD_STORE_DIR="${PREP_DIR}/password-store"
  echo "Cloning the password store from ${IMAGESET_PASSWORD_STORE_URL}..."
  git clone --quiet --depth 1 "${IMAGESET_PASSWORD_STORE_URL}" "${PASSWORD_STORE_DIR}"
}

# The token is stored in GH_CONFIG_DIR, rather than the user's keychain
function login-github {
  gh auth login --hostname github.com --git-protocol https --scopes workflow --insecure-storage --web
}

function login-aws {
  local account
  export AWS_PROFILE=community-tc-workers
  cat > "${AWS_CONFIG_FILE}" << EOF
[sso-session community-tc-imagesets]
sso_start_url = https://mozilla-cloudservices.awsapps.com/start
sso_region = us-west-2
sso_registration_scopes = sso:account:access

[profile ${AWS_PROFILE}]
sso_session = community-tc-imagesets
sso_account_id = ${AWS_ACCOUNT_ID}
sso_role_name = AdministratorAccess
region = us-east-1
EOF
  if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo "Signing in to AWS account moz-fx-tc-community-workers (${AWS_ACCOUNT_ID}) with Mozilla's AWS SSO..."
    if can-open-browser; then
      aws sso login --sso-session community-tc-imagesets
    else
      aws sso login --sso-session community-tc-imagesets --use-device-code
    fi
  fi
  account="$(aws sts get-caller-identity --query Account --output text)"
  if [ "${account}" != "${AWS_ACCOUNT_ID}" ]; then
    echo "AWS credentials are for account ${account}, rather than moz-fx-tc-community-workers (${AWS_ACCOUNT_ID})." >&2
    return 1
  fi
}

function push-to-main {
  if ! git pull --quiet --rebase --autostash "${OFFICIAL_GIT_REPO}" main; then
    git rebase --abort 2> /dev/null || true
    return 1
  fi
  git push "${OFFICIAL_GIT_REPO}" HEAD:refs/heads/main
}

# Runs this script from a clone of upstream main, rather than the user's checkout
function run-from-clone {
  local checkout="${IMAGESETS_DIR}/.."
  local clone
  local var
  PREP_DIR="$(mktemp -t deploy-worker-pools.XXXXXXXXXX -d)"
  trap 'status=$?; cd; rm -rf "${PREP_DIR}"; exit "${status}"' EXIT
  clone="${PREP_DIR}/community-tc-config"
  echo "Cloning ${OFFICIAL_GIT_REPO} (main) into ${clone}..."
  (
    for var in $(compgen -e); do
      case "${var}" in GIT_*) unset "${var}" ;; esac
    done
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
    git clone --quiet --branch main "${OFFICIAL_GIT_REPO}" "${clone}"
  )
  git --no-pager -C "${clone}" log -1 --format='Using upstream main at %h: %s'
  if "${IMAGESET_LOCAL_CHANGES}"; then
    echo "WARNING: IMAGESET_LOCAL_CHANGES=true: using the files of ${checkout} (other than config/) rather than upstream main's" >&2
    (
      cd "${checkout}"
      git ls-files -z --cached --others --exclude-standard -- . ':(exclude)config' |
        while IFS= read -r -d '' file; do
          [ -e "${file}" ] && printf '%s\0' "${file}"
        done |
        tar -cf - --null -T -
    ) | tar -C "${clone}" -xf -
  fi
  if ! grep -q IMAGESET_PREP_DIR "${clone}/imagesets/imageset.sh"; then
    echo "Upstream main's imageset.sh can't run from a clone yet: rerun with IMAGESET_LOCAL_CHANGES=true" >&2
    exit 1
  fi
  IMAGESET_PREP_DIR="${PREP_DIR}" exec "${clone}/imagesets/imageset.sh" "${IMAGESET_TARGET}"
}

function step-done {
  grep -qxF "${1}" "${STEPS_FILE}" 2> /dev/null
}

# Runs a step, unless resuming a previous run that completed it
function run-step {
  local step="${1}"
  shift
  if step-done "${step}"; then
    echo "Skipping ${step}: completed by a previous run"
    return
  fi
  CURRENT_STEP="${step}"
  "$@"
  echo "${step}" >> "${STEPS_FILE}"
  CURRENT_STEP=''
}

function update-offerings {
  echo "Updating EC2 instance types..."
  misc/update-ec2-instance-types.sh
  git add 'config/ec2-instance-type-offerings'
  git diff --cached --quiet || git commit -m "Ran script misc/update-ec2-instance-types.sh"

  echo "Updating Azure VM sizes..."
  misc/update-azure-vm-sizes.sh
  git add 'config/azure-vm-size-offerings'
  git diff --cached --quiet || git commit -m "Ran script misc/update-azure-vm-sizes.sh"

  echo "Updating GCE machine types..."
  misc/update-gce-machine-types.sh
  git add 'config/gce-machine-type-offerings.json'
  git diff --cached --quiet || git commit -m "Ran script misc/update-gce-machine-types.sh"

  retry push-to-main
  retry tc-admin apply
}

function update-mac {
  local host="${1}"
  retry-mac install-mac-files "${host}"
  # The lock stops a retry from running alongside an interrupted run
  retry-mac mac-ssh "${host}" sudo -n lockf -t 900 /var/run/com.mozilla.genericworker.update.lock /var/root/update.sh
}

function build-images {
  python3 imagesets/rel-sre-imagesets.py
  git add config/imagesets.yml
  git diff --cached --quiet || git commit -m "Use new machine images built by mozilla-platform-ops/worker-images"
  retry push-to-main
}

function deploy-images {
  python3 imagesets/copy-azure-images.py
  retry tc-admin apply
}

# On failure, says how to resume; on success, forgets the completed steps
function finish {
  local status="${1}"
  if [ "${status}" == 0 ]; then
    if [ -n "${STEPS_FILE}" ]; then
      rm -f "${STEPS_FILE}" "${IMAGESET_RUNS_FILE}"
    fi
  elif [ -n "${STEPS_FILE}" ]; then
    echo >&2
    echo "imageset.sh failed${CURRENT_STEP:+ during step: ${CURRENT_STEP}}. To continue from there, rerun the same command: it will offer to resume." >&2
  fi
}

# Progress, kept outside PREP_DIR for resuming. No secrets.
function state-paths {
  STATE_DIR="${TMPDIR:-/tmp}/community-tc-imagesets-$(id -u)"
  STEPS_FILE="${STATE_DIR}/${IMAGESET_TARGET}.steps"
  # The worker-images runs that rel-sre-imagesets.py waits for
  IMAGESET_RUNS_FILE="${STATE_DIR}/${IMAGESET_TARGET}.runs.json"
}

# Asks whether to resume an unfinished run of the same target, unless
# IMAGESET_RESUME says
function choose-resume {
  local answer
  case "${IMAGESET_RESUME-}" in
    true | false | '') ;;
    *) echo "IMAGESET_RESUME must be true or false" >&2; return 1 ;;
  esac
  state-paths
  if [ -n "${IMAGESET_RESUME-}" ] || ! { [ -f "${STEPS_FILE}" ] || [ -f "${IMAGESET_RUNS_FILE}" ]; }; then
    export IMAGESET_RESUME="${IMAGESET_RESUME:-false}"
    return
  fi
  echo "A previous ${IMAGESET_TARGET} run didn't finish."
  if [ -f "${STEPS_FILE}" ]; then
    echo "Steps it completed: $(paste -sd , - < "${STEPS_FILE}")"
  fi
  if [ -f "${IMAGESET_RUNS_FILE}" ]; then
    echo "It triggered worker-images builds, which resuming waits for, rather than triggering new ones."
  fi
  if ! [ -t 0 ]; then
    echo "Set IMAGESET_RESUME=true to resume it, or IMAGESET_RESUME=false to start again." >&2
    return 1
  fi
  while true; do
    read -r -p "Resume it (r), or delete its progress and start again (s)? " answer
    case "${answer}" in
      r | R) IMAGESET_RESUME=true; break ;;
      s | S) IMAGESET_RESUME=false; break ;;
    esac
  done
  export IMAGESET_RESUME
}

############### Deploy image sets ###############

function set-defaults {
  # Steps that only concern production (the Taskcluster version that prod
  # images pin, macOS workers, and instance offerings) are skipped by default
  # when only staging image sets are deployed.
  local prod_default=true
  if [ "${IMAGESET_TARGET}" == "staging" ]; then
    prod_default=false
  fi

  : ${BUILD_IMAGES:=true}

  : ${DEPLOY_IMAGES:=true}
  # Bump worker-images' TCEng configs to the latest Taskcluster release (via a PR
  # that must be merged) before triggering worker-images builds
  : ${UPDATE_TASKCLUSTER_VERSION:=${prod_default}}
  export UPDATE_TASKCLUSTER_VERSION
  # Open a PR to have fxci's worker pools use the new images too
  : ${UPDATE_FXCI_IMAGES:=true}
  : ${DEPLOY_MACS:=${prod_default}}

  : ${UPDATE_GCLOUD:=true}
  : ${UPDATE_OFFERINGS:=${prod_default}}

  : ${IMAGESET_LOCAL_CHANGES:=false}
}

# Deploys the image sets of IMAGESET_TARGET: prod, staging or all.
function deploy-image-sets {
  # TODO: fetch these hosts automatically
  local MAC_HOSTS=(
    macmini-m4-126.test.releng.mdc1.mozilla.com
    macmini-m4-127.test.releng.mdc1.mozilla.com
  )

  isolate-environment

  export GCP_PROJECT=taskcluster-imaging
  export AZURE_IMAGE_RESOURCE_GROUP=rg-tc-eng-images
  # Taskcluster Engineering DevTest Subscription
  export AZURE_SUBSCRIPTION_ID=8a205152-b25a-417f-a676-80465535a6c9
  # moz-fx-tc-community-workers
  export AWS_ACCOUNT_ID=885316786408

  export TASKCLUSTER_CLIENT_ID='static/taskcluster/root'
  export TASKCLUSTER_ROOT_URL='https://community-tc.services.mozilla.com'

  if "${UPDATE_GCLOUD}"; then
    retry update-gcloud
  fi
  if can-open-browser; then
    retry gcloud auth login
  else
    retry gcloud auth login --no-launch-browser
  fi

  login-github

  # For a terminal pinentry
  if [ -t 0 ]; then
    GPG_TTY="$(tty)"
    export GPG_TTY
  fi
  clone-password-store
  local root_credentials
  root_credentials="$(read-pass community-tc/root)"
  local taskcluster_access_token="${root_credentials%%$'\n'*}"
  if [ -z "${taskcluster_access_token}" ]; then
    echo "No access token in pass entry community-tc/root" >&2
    exit 1
  fi

  # Only the macOS workers that a resumed run hasn't updated yet
  local pending_macs=()
  if "${DEPLOY_MACS}"; then
    for HOST in "${MAC_HOSTS[@]}"; do
      step-done "mac ${HOST}" || pending_macs+=("${HOST}")
    done
  fi
  if [ "${#pending_macs[@]}" -gt 0 ]; then
    read-mac-passwords "${pending_macs[@]}"
  fi
  # Read by tc-admin (generate/secret_values.py)
  cache-pass-entry community-tc/secret-values.yml
  disable-passphrase-prompts
  if [ "${#pending_macs[@]}" -gt 0 ]; then
    check-mac-connectivity "${pending_macs[@]}"
  fi

  if can-open-browser; then
    retry az login --tenant mozilla.com --subscription "${AZURE_SUBSCRIPTION_ID}"
  else
    retry az login --tenant mozilla.com --subscription "${AZURE_SUBSCRIPTION_ID}" --use-device-code
  fi
  az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

  if "${UPDATE_OFFERINGS}" && ! step-done offerings; then
    login-aws
  fi

  cd "${PREP_DIR}"
  mkdir tc-admin

  cd tc-admin
  python3 -m venv tc-admin-venv
  source tc-admin-venv/bin/activate
  pip3 install pytest
  pip3 install --upgrade pip

  cd "${IMAGESETS_DIR}/.."

  pip3 install -e .
  command -v tc-admin

  # Only after installing packages, which needn't see them
  export TASKCLUSTER_ACCESS_TOKEN="${taskcluster_access_token}"
  GITHUB_TOKEN="$(gh auth token)"
  export GITHUB_TOKEN

  if "${BUILD_IMAGES}" && "${UPDATE_TASKCLUSTER_VERSION}"; then
    # The worker-images PR needs someone to review and merge it, so open it
    # before anything else. Only triggering the image builds waits for it to be merged
    # (in rel-sre-imagesets.py below); the steps in between don't depend on it.
    run-step bump-pr python3 imagesets/rel-sre-imagesets.py --open-bump-pr
  fi

  if "${UPDATE_OFFERINGS}"; then
    run-step offerings update-offerings
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
      run-step "mac ${HOST}" update-mac "${HOST}"
    done
  fi

  if "${BUILD_IMAGES}"; then
    run-step build-images build-images
  fi

  if "${DEPLOY_IMAGES}"; then
    # Images must exist before tc-admin points worker pools at them
    run-step deploy-images deploy-images
  fi

  if "${BUILD_IMAGES}"; then
    python3 imagesets/rel-sre-imagesets.py --log-images
    # fxci's config can only be changed with a reviewed PR
    if "${UPDATE_FXCI_IMAGES}"; then
      run-step fxci-pr python3 imagesets/rel-sre-imagesets.py --open-fxci-pr
    fi
  fi

  echo "All done!"
}

################## Entry point ##################

cd "$(dirname "${0}")"

IMAGESETS_DIR="$(pwd)"

export OFFICIAL_GIT_REPO='https://github.com/taskcluster/community-tc-config'
: ${IMAGESET_PASSWORD_STORE_URL:=https://source.developers.google.com/p/taskcluster-passwords/r/secrets}

# See README.md for the environment variables that control which steps run.
if [ "${#}" -ne 1 ] || ! [[ "${1}" =~ ^(prod|staging|all)$ ]]; then
  echo "Usage: ${0} prod|staging|all" >&2
  echo "Has mozilla-platform-ops/worker-images build the production image sets (prod), the staging image sets (staging), or both (all), and deploys them; see README.md." >&2
  exit 64
fi

export IMAGESET_TARGET="${1}"

set-defaults

if [ -z "${IMAGESET_PREP_DIR-}" ]; then
  check-required-tools
  choose-resume
  run-from-clone
fi

if [ "$(pwd -P)" != "$(cd "${IMAGESET_PREP_DIR}" && pwd -P)/community-tc-config/imagesets" ]; then
  echo "IMAGESET_PREP_DIR is only for imageset.sh's own use: unset it" >&2
  exit 64
fi
PREP_DIR="${IMAGESET_PREP_DIR}"
unset IMAGESET_PREP_DIR
PASS_CACHE="${PREP_DIR}/pass-cache"

STEPS_FILE=''
IMAGESET_RUNS_FILE=''
CURRENT_STEP=''
trap 'status=$?; cd; rm -rf "${PREP_DIR}"; finish "${status}"; exit "${status}"' EXIT

state-paths
export IMAGESET_RUNS_FILE
mkdir -p -m 700 "${STATE_DIR}"
if [ -L "${STATE_DIR}" ] || ! [ -O "${STATE_DIR}" ]; then
  echo "${STATE_DIR} isn't a directory of yours" >&2
  STEPS_FILE=''
  exit 1
fi
if ! "${IMAGESET_RESUME:-false}"; then
  rm -f "${STEPS_FILE}" "${IMAGESET_RUNS_FILE}"
elif [ -f "${STEPS_FILE}" ] || [ -f "${IMAGESET_RUNS_FILE}" ]; then
  echo "Resuming a previous run"
  if [ -f "${STEPS_FILE}" ]; then
    echo "Skipping the steps it completed: $(paste -sd , - < "${STEPS_FILE}")"
  fi
else
  echo "Nothing to resume: running all the steps"
fi
echo
echo "Preparing in directory ${PREP_DIR}..."
echo
deploy-image-sets
