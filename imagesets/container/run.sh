#!/usr/bin/env bash
# Deploys image sets: run by imageset.sh (which see), in its container, with:
#
#   /work        a clone of this repository (upstream main, or with your
#                changes, for IMAGESET_LOCAL_CHANGES=true)
#   /state       progress for resuming, and your VPN bundle (encrypted to your
#                gpg key), kept between runs
#   /bridge      where open-url asks imageset.sh to open your browser
#   /host-gnupg  your gpg home (read-only)
#
# The tools are the image's, and only see this container: they sign in during
# the run, through your browser (on the host).

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

# Sets MAC_SSH_OPTIONS, for ssh to the macOS workers as administrator.
# StrictHostKeyChecking, as SSH_ASKPASS would answer a host key prompt.
function mac-ssh-options {
  MAC_SSH_OPTIONS=(
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
}

# Run a command on a macOS worker as administrator. stdin isn't passed to the
# command, unless MAC_SSH_STDIN=true.
function mac-ssh {
  local host="${1}"
  shift
  local password_var="MAC_PASSWORD_$(mac-name "${host}")"
  local ssh_options
  mac-ssh-options
  ssh_options=("${MAC_SSH_OPTIONS[@]}")
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
  # Before the pipeline, where a missing file wouldn't stop it
  for entry in "${MAC_FILES[@]}"; do
    IFS=: read -r file dest mode <<< "${entry}"
    if ! [ -f "${IMAGESETS_DIR}/../misc/mac/${file}" ]; then
      echo "misc/mac/${file} is missing" >&2
      return 1
    fi
  done
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


function read-pass {
  local entry="${1}"
  if ! with-gpg pass show "${entry}"; then
    echo "Couldn't decrypt ${entry} from the password store. Check that your gpg key is one that the password store is encrypted to (see ${PASSWORD_STORE_DIR}/.gpg-id)." >&2
    return 1
  fi
}

# The fingerprint of the gpg key that commits are signed with, and the password
# store decrypted with: user.signingkey, or else the key of user.email
function find-gpg-key {
  local key
  local fprs
  key="${IMAGESET_GIT_SIGNINGKEY%!}"
  key="${key:-<${IMAGESET_GIT_EMAIL}>}"
  # Keys that can sign and encrypt (uppercase capabilities are the usable ones)
  fprs="$(GNUPGHOME="${HOST_GNUPGHOME}" gpg --batch --with-colons --list-secret-keys -- "${key}" 2> /dev/null |
    awk -F: '$1 == "sec" && $12 ~ /S/ && $12 ~ /E/ { sec = 1; next } sec && $1 == "fpr" { print $10 } { sec = 0 }')" || true
  case "$(printf '%s' "${fprs}" | grep -c .)" in
    1) echo "${fprs}" ;;
    0)
      echo "No usable gpg secret key (that can sign and encrypt) matches ${key}: set user.signingkey to the fingerprint of yours (git config --global user.signingkey <fingerprint>). Commits are always signed with it." >&2
      return 1
      ;;
    *)
      echo "Several gpg secret keys match ${key}: set user.signingkey to the fingerprint of the one to use (git config --global user.signingkey <fingerprint>)." >&2
      return 1
      ;;
  esac
}

# gpg (for the password store, and signing commits) uses an agent of its own,
# with a copy of the key (IMAGESET_GPG_KEY), from your gpg home
# (HOST_GNUPGHOME, a copy of the read-only /host-gnupg). The agent caches nothing, so nothing
# can use the key through its socket. Instead, the passphrase is asked for at
# the start, kept in GPG_PASSPHRASE (not exported), and given only to the
# commands that need it, by with-gpg. gpg, on PATH, is a wrapper that reads it
# from there, or fails (rather than prompts) if it can't.
function setup-gpg {
  local real_gpg
  local bin="${PREP_DIR}/bin"
  local name
  local grip
  local type
  local protection
  local protected=false
  local found=false
  unset GPG_PASSPHRASE
  real_gpg="$(command -v gpg)"
  # Short, as the agent's socket path is limited to about 100 characters
  RUN_GNUPGHOME="$(mktemp -d /tmp/imageset-gnupg.XXXXXXXX)"
  export GNUPGHOME="${RUN_GNUPGHOME}"
  printf 'default-cache-ttl 0\nmax-cache-ttl 0\nallow-loopback-pinentry\nno-allow-external-cache\ndisable-scdaemon\npinentry-program %s\n' "$(type -P false)" > "${GNUPGHOME}/gpg-agent.conf"
  GNUPGHOME="${HOST_GNUPGHOME}" "${real_gpg}" --batch --export "${IMAGESET_GPG_KEY}" |
    "${real_gpg}" --batch --quiet --import
  # The private key files are encrypted with the passphrase
  mkdir -p -m 700 "${GNUPGHOME}/private-keys-v1.d"
  for grip in $(GNUPGHOME="${HOST_GNUPGHOME}" "${real_gpg}" --batch --with-colons --with-keygrip --list-secret-keys "${IMAGESET_GPG_KEY}" | awk -F: '$1 == "grp" { print $10 }'); do
    if [ -f "${HOST_GNUPGHOME}/private-keys-v1.d/${grip}.key" ]; then
      cp "${HOST_GNUPGHOME}/private-keys-v1.d/${grip}.key" "${GNUPGHOME}/private-keys-v1.d/"
    fi
  done
  while read -r grip type protection; do
    found=true
    if [ "${type}" == T ]; then
      echo "Your gpg key ${IMAGESET_GPG_KEY} is on a smartcard, which imageset.sh doesn't support." >&2
      return 1
    fi
    if [ "${protection}" == P ]; then
      protected=true
    fi
  done < <(gpg-connect-agent 'KEYINFO --list' /bye | awk '$1 == "S" && $2 == "KEYINFO" { print $3, $4, $8 }')
  if ! "${found}"; then
    echo "No private key of ${IMAGESET_GPG_KEY} in ${IMAGESET_GNUPG_HOME_ON_HOST}/private-keys-v1.d" >&2
    return 1
  fi

  mkdir -p "${bin}"
  for name in gpg gpg2; do
    cat > "${bin}/${name}" << EOF
#!/bin/sh
# With the passphrase from imageset.sh's with-gpg, if the key has one (in a
# subshell, as a redirection error exits dash)
if ( : <&7 ) 2> /dev/null; then
  exec '${real_gpg}' --batch --pinentry-mode loopback --passphrase-fd 7 "\$@"
fi
exec '${real_gpg}' --batch --pinentry-mode error "\$@"
EOF
    chmod 755 "${bin}/${name}"
  done
  export PATH="${bin}:${PATH}"

  stop-host-gnupg
  if "${protected}"; then
    read-gpg-passphrase
    # For the Python scripts, as subprocess closes other file descriptors
    export IMAGESET_GPG_PASSPHRASE_FD=7
  elif ! check-gpg-key; then
    echo "Your gpg key ${IMAGESET_GPG_KEY} can't sign and decrypt." >&2
    return 1
  fi
}

function stop-gpg {
  if [ -n "${RUN_GNUPGHOME}" ]; then
    GNUPGHOME="${RUN_GNUPGHOME}" gpgconf --kill gpg-agent 2> /dev/null || true
    rm -rf "${RUN_GNUPGHOME}"
  fi
}

function read-gpg-passphrase {
  local uid
  # Reading all of gpg's output, which pipefail would otherwise fail on
  uid="$(gpg --with-colons --list-keys "${IMAGESET_GPG_KEY}" | awk -F: '$1 == "uid" && !found { print $10; found = 1 }')"
  if ! [ -t 0 ]; then
    echo "imageset.sh needs a terminal, to ask for the passphrase of your gpg key." >&2
    return 1
  fi
  while true; do
    IFS= read -r -s -p "Passphrase for your gpg key ${IMAGESET_GPG_KEY} (${uid}): " GPG_PASSPHRASE
    echo
    if with-gpg check-gpg-key 2> /dev/null; then
      return
    fi
    echo "That passphrase was rejected. Try again (or press Ctrl-C to stop)." >&2
  done
}

# Signs, and decrypts a message encrypted to, IMAGESET_GPG_KEY. One gpg at a
# time, as each reads a line of with-gpg's passphrase.
function check-gpg-key {
  local message
  message="$(echo imageset | gpg --quiet --trust-model always --armor --encrypt --recipient "${IMAGESET_GPG_KEY}")" &&
    [ "$(printf '%s\n' "${message}" | gpg --quiet --decrypt)" == imageset ] &&
    echo imageset | gpg --quiet --local-user "${IMAGESET_GPG_KEY}" --detach-sign > /dev/null
}

# Runs a command with the gpg passphrase (if the key has one) on file
# descriptor 7, for the gpg wrapper of setup-gpg
function with-gpg {
  if [ -z "${GPG_PASSPHRASE-}" ]; then
    "$@"
    return
  fi
  "$@" 7< <(gpg-passphrase-lines)
}

# A line for each gpg that reads it
function gpg-passphrase-lines {
  local i
  for ((i = 0; i < 1000; i++)); do
    printf '%s\n' "${GPG_PASSPHRASE}"
  done
}

# Fails unless each commit of a range is signed with IMAGESET_GPG_KEY
function check-signed {
  local commit
  local status
  for commit in $(git rev-list "${1}"); do
    status="$(git verify-commit --raw "${commit}" 2>&1 || true)"
    # The last field of VALIDSIG is the primary key's fingerprint
    if ! printf '%s\n' "${status}" | grep -q "^\[GNUPG:\] VALIDSIG .* ${IMAGESET_GPG_KEY}\$"; then
      echo "Commit ${commit} isn't signed with ${IMAGESET_GPG_KEY}: not pushing it." >&2
      return 1
    fi
  done
}

# gpg needs a passphrase only from with-gpg, so can't prompt. ssh keys aren't
# needed (git uses HTTPS, and ssh to the macOS workers uses passwords), so
# fail rather than prompt for a passphrase.
function disable-ssh-keys {
  local bin="${PREP_DIR}/bin"
  mkdir -p "${bin}"
  printf '#!/bin/sh\necho "imageset.sh: ssh keys are disabled" >&2\nexit 1\n' > "${bin}/ssh-for-git"
  chmod 755 "${bin}/ssh-for-git"
  export GIT_SSH_COMMAND="${bin}/ssh-for-git"
  unset SSH_AUTH_SOCK
}

function clone-password-store {
  export PASSWORD_STORE_DIR="${PREP_DIR}/password-store"
  echo "Cloning the password store from ${IMAGESET_PASSWORD_STORE_URL}..."
  git clone --quiet --depth 1 "${IMAGESET_PASSWORD_STORE_URL}" "${PASSWORD_STORE_DIR}"
}

function filter-aws-login {
  local line
  local code=false
  while IFS= read -r line; do
    case "${line}" in
      "" | "Attempting to open your default browser." | "If the browser does not open"* | https://*) ;;
      "Then enter the code:") code=true ;;
      *)
        if "${code}"; then
          echo "The page should show the code ${line}."
          code=false
        else
          echo "${line}"
        fi
        ;;
    esac
  done
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
  echo "Signing in to AWS account moz-fx-tc-community-workers (${AWS_ACCOUNT_ID}) with Mozilla's AWS SSO..."
  # A device code, as the browser (on the host) can't reach a callback server
  # in the container on a random port. Its instructions are only needed if the
  # browser can't be opened (open-url says what it opened).
  if "${IMAGESET_HOST_BROWSER}"; then
    aws sso login --sso-session community-tc-imagesets --use-device-code 2>&1 | filter-aws-login
  else
    aws sso login --sso-session community-tc-imagesets --use-device-code --no-browser
  fi
  account="$(aws sts get-caller-identity --query Account --output text)"
  if [ "${account}" != "${AWS_ACCOUNT_ID}" ]; then
    echo "AWS credentials are for account ${account}, rather than moz-fx-tc-community-workers (${AWS_ACCOUNT_ID})." >&2
    return 1
  fi
}

function push-to-main {
  if ! with-gpg git pull --quiet --rebase --autostash "${OFFICIAL_GIT_REPO}" main; then
    git rebase --abort 2> /dev/null || true
    return 1
  fi
  # Exits, rather than returns, as retry runs this as a condition (where set -e
  # is off), and retrying wouldn't help
  if ! check-signed FETCH_HEAD..HEAD; then
    exit 1
  fi
  git push "${OFFICIAL_GIT_REPO}" HEAD:refs/heads/main
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
  git diff --cached --quiet || with-gpg git commit -m "Ran script misc/update-ec2-instance-types.sh"

  echo "Updating Azure VM sizes..."
  misc/update-azure-vm-sizes.sh
  git add 'config/azure-vm-size-offerings'
  git diff --cached --quiet || with-gpg git commit -m "Ran script misc/update-azure-vm-sizes.sh"

  echo "Updating GCE machine types..."
  misc/update-gce-machine-types.sh
  git add 'config/gce-machine-type-offerings.json'
  git diff --cached --quiet || with-gpg git commit -m "Ran script misc/update-gce-machine-types.sh"

  retry push-to-main
  retry with-gpg tc-admin apply
}

function update-mac {
  local host="${1}"
  retry-mac install-mac-files "${host}"
  # The lock stops a retry from running alongside an interrupted run
  retry-mac mac-ssh "${host}" sudo -n lockf -t 900 /var/run/com.mozilla.genericworker.update.lock /var/root/update.sh
}

function build-images {
  with-gpg python3 imagesets/rel-sre-imagesets.py
  git add config/imagesets.yml
  git diff --cached --quiet || with-gpg git commit -m "Use new machine images built by mozilla-platform-ops/worker-images"
  retry push-to-main
}

function deploy-images {
  python3 imagesets/copy-azure-images.py
  retry with-gpg tc-admin apply
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
    if [ -f "${STEPS_FILE}" ] || [ -f "${IMAGESET_RUNS_FILE}" ]; then
      echo "imageset.sh failed${CURRENT_STEP:+ during step: ${CURRENT_STEP}}. To continue from there, rerun the same command: it will offer to resume." >&2
    else
      echo "imageset.sh failed${CURRENT_STEP:+ during step: ${CURRENT_STEP}}, before completing any step: rerun the same command to start again." >&2
    fi
  fi
}

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

  : ${UPDATE_OFFERINGS:=${prod_default}}

  # As they are run (as true or false)
  local setting
  for setting in BUILD_IMAGES DEPLOY_IMAGES UPDATE_TASKCLUSTER_VERSION UPDATE_FXCI_IMAGES DEPLOY_MACS UPDATE_OFFERINGS IMAGESET_HOST_BROWSER; do
    case "${!setting-}" in
      true | false) ;;
      *) echo "${setting} must be true or false, rather than '${!setting-}'" >&2; exit 64 ;;
    esac
  done
}

# The tools' configuration, other than for gpg (setup-gpg)
function configure-tools {
  export GIT_CONFIG_GLOBAL="${PREP_DIR}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_TERMINAL_PROMPT=0
  git config --global user.name "${IMAGESET_GIT_NAME}"
  git config --global user.email "${IMAGESET_GIT_EMAIL}"
  # Whatever your own settings, with the wrapper of setup-gpg
  git config --global commit.gpgsign true
  git config --global tag.gpgsign true
  git config --global gpg.format openpgp
  git config --global user.signingkey "${IMAGESET_GPG_KEY}"
  git config --global gpg.program "${PREP_DIR}/bin/gpg"
  git config --global credential.https://github.com.helper '!gh auth git-credential'
  git config --global credential.https://source.developers.google.com.helper '!gcloud auth git-helper --ignore-unknown "$@"'
  # The clone is owned by your user on the host, rather than root
  git config --global --add safe.directory '*'

  export GH_CONFIG_DIR="${PREP_DIR}/gh"
  mkdir "${GH_CONFIG_DIR}"
  printf 'version: 1\ngit_protocol: https\nprompt: disabled\n' > "${GH_CONFIG_DIR}/config.yml"

  export CLOUDSDK_CONFIG="${PREP_DIR}/gcloud"
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1

  export AZURE_CONFIG_DIR="${PREP_DIR}/azure"
  export AZURE_CORE_LOGIN_EXPERIENCE_V2=off
  export AZURE_CORE_COLLECT_TELEMETRY=false

  export AWS_CONFIG_FILE="${PREP_DIR}/aws-config"
  export AWS_SHARED_CREDENTIALS_FILE=/dev/null
  export AWS_PAGER=''

  # Opens your browser, on the host
  export BROWSER="${IMAGESETS_DIR}/container/open-url"

  # A pager would wait for a key press
  export PAGER=cat GIT_PAGER=cat GH_PAGER=cat
}

# Your keys, from your gpg home (/host-gnupg, read-only), in HOST_GNUPGHOME,
# for find-gpg-key and setup-gpg (which only keeps IMAGESET_GPG_KEY). Only the
# keys: none of your gpg configuration. The public keys may be in keyboxd's
# database (gpg 2.4 and later, if configured), a keybox (gpg 2.1 and later),
# or a keyring (gpg 1).
function copy-host-gnupg {
  local file
  HOST_GNUPGHOME="$(mktemp -d /tmp/host-gnupg.XXXXXXXX)"
  if [ -f /host-gnupg/public-keys.d/pubring.db ]; then
    mkdir -m 700 "${HOST_GNUPGHOME}/public-keys.d"
    cp /host-gnupg/public-keys.d/pubring.db "${HOST_GNUPGHOME}/public-keys.d/"
    echo use-keyboxd > "${HOST_GNUPGHOME}/common.conf"
  else
    for file in pubring.kbx pubring.gpg; do
      if [ -f "/host-gnupg/${file}" ]; then
        cp "/host-gnupg/${file}" "${HOST_GNUPGHOME}/"
      fi
    done
  fi
  mkdir -m 700 "${HOST_GNUPGHOME}/private-keys-v1.d"
  if ls /host-gnupg/private-keys-v1.d/*.key > /dev/null 2>&1; then
    cp /host-gnupg/private-keys-v1.d/*.key "${HOST_GNUPGHOME}/private-keys-v1.d/"
  fi
}

function stop-host-gnupg {
  if [ -n "${HOST_GNUPGHOME}" ] && [ -d "${HOST_GNUPGHOME}" ]; then
    GNUPGHOME="${HOST_GNUPGHOME}" gpgconf --kill all 2> /dev/null || true
    rm -rf "${HOST_GNUPGHOME}"
  fi
}

# Asks for your name and email for commits, offering the current ones
function ask-identity {
  local answer
  while true; do
    read -r -p "Your name, for commits${IMAGESET_GIT_NAME:+ [${IMAGESET_GIT_NAME}]}: " answer
    IMAGESET_GIT_NAME="${answer:-${IMAGESET_GIT_NAME}}"
    [ -n "${IMAGESET_GIT_NAME}" ] && break
  done
  while true; do
    read -r -p "Your email, for commits${IMAGESET_GIT_EMAIL:+ [${IMAGESET_GIT_EMAIL}]}: " answer
    IMAGESET_GIT_EMAIL="${answer:-${IMAGESET_GIT_EMAIL}}"
    [[ "${IMAGESET_GIT_EMAIL}" == ?*@?* ]] && break
  done
  # Your git configuration's signing key may not be for the new email
  IMAGESET_GIT_SIGNINGKEY=''
}

# The repositories that this run commits to, as "repository: how", one per line
function repositories {
  if "${UPDATE_OFFERINGS}" || "${BUILD_IMAGES}"; then
    echo "taskcluster/community-tc-config: pushed to main"
  fi
  if "${BUILD_IMAGES}" && "${UPDATE_TASKCLUSTER_VERSION}"; then
    echo "mozilla-platform-ops/worker-images: a pull request, from a branch there"
  fi
  if "${BUILD_IMAGES}" && "${UPDATE_FXCI_IMAGES}"; then
    echo "mozilla-releng/fxci-config: a pull request, from your fork"
  fi
}

# Your name and email for commits (from your git configuration, if you have
# it), and the gpg key that signs them (IMAGESET_GPG_KEY), which you confirm,
# or change
function confirm-identity {
  local answer
  local uid
  if [ -z "${IMAGESET_GIT_NAME}" ] || [ -z "${IMAGESET_GIT_EMAIL}" ]; then
    ask-identity
  fi
  while true; do
    if ! IMAGESET_GPG_KEY="$(find-gpg-key)"; then
      ask-identity
      continue
    fi
    uid="$(GNUPGHOME="${HOST_GNUPGHOME}" gpg --with-colons --list-keys "${IMAGESET_GPG_KEY}" |
      awk -F: -v email="<${IMAGESET_GIT_EMAIL}>" '$1 == "uid" { if (!first) first = $10; if (index($10, email)) match_ = $10 } END { print (match_ ? match_ : first) }')"
    echo
    echo "Commits will be made as ${IMAGESET_GIT_NAME} <${IMAGESET_GIT_EMAIL}>, signed with your gpg key ${IMAGESET_GPG_KEY} (${uid}), with the GitHub account you sign in with, to:"
    repositories | sed 's/^/  - /'
    read -r -p "Use these (Y), or change the name and email (c)? " answer
    case "${answer}" in
      "" | y | Y | yes) break ;;
      c | C) ask-identity ;;
    esac
  done
  export IMAGESET_GIT_NAME IMAGESET_GIT_EMAIL IMAGESET_GPG_KEY
}

# Suggests your LDAP username, for the VPN: your git email, or else a
# mozilla.com email of your GitHub account
function suggest-ldap-username {
  if [[ "${IMAGESET_GIT_EMAIL}" == *@mozilla.com ]]; then
    echo "${IMAGESET_GIT_EMAIL}"
  else
    gh api user/emails --jq '[.[] | select(.verified and (.email | endswith("@mozilla.com"))) | .email][0] // empty' 2> /dev/null || true
  fi
}

# gcloud waits for your browser (on the host) to be sent to
# http://localhost:8085/, which imageset.sh publishes to this container. As
# gcloud only listens on the container's localhost, socat forwards to it.
function login-gcloud {
  local address
  local socat_pid
  if ! "${IMAGESET_HOST_BROWSER}"; then
    retry gcloud auth login --no-launch-browser --quiet
    return
  fi
  address="$(ip -4 -o addr show eth0 | awk '{ print $4 }' | cut -d/ -f1)"
  socat "TCP-LISTEN:8085,bind=${address},fork,reuseaddr" TCP:127.0.0.1:8085 &
  socat_pid=$!
  # gcloud only launches a browser if there's a display. Its messages go to a
  # file, as it doesn't launch one if they go to a pipe.
  if ! DISPLAY=imageset gcloud auth login --quiet 2> "${PREP_DIR}/gcloud-login.log"; then
    kill "${socat_pid}" 2> /dev/null || true
    cat "${PREP_DIR}/gcloud-login.log" >&2
    echo "Signing in to Google Cloud failed." >&2
    return 1
  fi
  kill "${socat_pid}" 2> /dev/null || true
  wait "${socat_pid}" 2> /dev/null || true
  echo "Signed in to Google Cloud as $(gcloud auth list --filter=status:ACTIVE --format='value(account)')."
}

# The token is stored in GH_CONFIG_DIR, in the container. gh only shows the
# code and URL (as prompts are disabled), which are opened in your browser.
function login-github {
  local line
  local code=''
  # user:email and read:gpg_key, to check that your commits will show as verified
  gh auth login --hostname github.com --git-protocol https --scopes workflow,read:org,user:email,read:gpg_key --insecure-storage --web 2>&1 |
    while IFS= read -r line; do
      case "${line}" in
        *"one-time code: "*) code="${line##* }" ;;
        *"to continue in your web browser: https://github.com/"*) "${BROWSER}" "${line##* }" "${code}" ;;
        # gh can't copy to the container's clipboard (open-url copies to yours)
        "" | *clipboard* | *"Press Enter"* | *"Authentication credentials saved in plain text"* | *"gh config set"* | *"Configured git protocol"*) ;;
        *) echo "${line}" ;;
      esac
    done
}

# With a device code, opened in your browser
function login-azure {
  local line
  az login --tenant mozilla.com --use-device-code --output none 2>&1 |
    while IFS= read -r line; do
      if [[ "${line}" =~ (https://[^ ]+)\ and\ enter\ the\ code\ ([A-Z0-9]+) ]]; then
        "${BROWSER}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      else
        echo "${line}"
      fi
    done
  az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
}

function vpn {
  with-gpg python3 "${IMAGESETS_DIR}/container/vpn.py" "$@"
}

# The macOS workers are only reachable through the VPN, which is only
# connected for them, while you are there (it needs a 2FA code to connect, and
# again to reconnect).
function update-macs {
  local host
  vpn connect
  VPN_CONNECTED=true
  check-mac-connectivity "$@"
  for host in "$@"; do
    run-step "mac ${host}" update-mac "${host}"
  done
  vpn disconnect
  VPN_CONNECTED=false
}

function on-exit {
  local status="${1}"
  cd /
  if "${VPN_CONNECTED}"; then
    vpn disconnect > /dev/null 2>&1 || true
  fi
  stop-gpg
  stop-host-gnupg
  rm -rf "${PREP_DIR}"
  # Files written as root are yours, on the host, with Docker on Linux, where
  # the mounts show your uid (rather than with rootless Docker, where root is
  # you, or Docker on macOS, which maps them)
  if [ "$(stat -c %u /state)" == "${IMAGESET_HOST_UID}" ] && [ "${IMAGESET_HOST_UID}" != 0 ]; then
    chown -R "${IMAGESET_HOST_UID}:${IMAGESET_HOST_GID}" /work /state 2> /dev/null || true
  fi
  finish "${status}"
}

############### Deploy image sets ###############

# Deploys the image sets of IMAGESET_TARGET: prod, staging or all.
function deploy-image-sets {
  # TODO: fetch these hosts automatically
  local MAC_HOSTS=(
    macmini-m4-126.test.releng.mdc1.mozilla.com
    macmini-m4-127.test.releng.mdc1.mozilla.com
  )
  local host

  export GCP_PROJECT=taskcluster-imaging
  export AZURE_IMAGE_RESOURCE_GROUP=rg-tc-eng-images
  # Taskcluster Engineering DevTest Subscription
  export AZURE_SUBSCRIPTION_ID=8a205152-b25a-417f-a676-80465535a6c9
  # moz-fx-tc-community-workers
  export AWS_ACCOUNT_ID=885316786408

  export TASKCLUSTER_CLIENT_ID='static/taskcluster/root'
  export TASKCLUSTER_ROOT_URL='https://community-tc.services.mozilla.com'

  # Everything that needs you happens first: the gpg passphrase, the VPN
  # bundle (if it isn't stored yet), the sign-ins, and connecting to the VPN
  # for the macOS workers. The rest runs unattended.
  copy-host-gnupg
  confirm-identity
  configure-tools
  setup-gpg

  # Only the macOS workers that a resumed run hasn't updated yet
  local pending_macs=()
  if "${DEPLOY_MACS}"; then
    for host in "${MAC_HOSTS[@]}"; do
      step-done "mac ${host}" || pending_macs+=("${host}")
    done
  fi

  echo "Signing in to Google Cloud..."
  login-gcloud
  echo "Signing in to GitHub..."
  login-github
  echo "Signing in to Azure..."
  login-azure
  if "${UPDATE_OFFERINGS}" && ! step-done offerings; then
    login-aws
  fi

  if [ "${#pending_macs[@]}" -gt 0 ]; then
    IMAGESET_LDAP_SUGGESTION="$(suggest-ldap-username)"
    export IMAGESET_LDAP_SUGGESTION
    vpn prepare
  fi

  clone-password-store
  local root_credentials
  root_credentials="$(read-pass community-tc/root)"
  local taskcluster_access_token="${root_credentials%%$'\n'*}"
  if [ -z "${taskcluster_access_token}" ]; then
    echo "No access token in pass entry community-tc/root" >&2
    exit 1
  fi
  if [ "${#pending_macs[@]}" -gt 0 ]; then
    read-mac-passwords "${pending_macs[@]}"
  fi
  disable-ssh-keys

  cd "${IMAGESETS_DIR}/.."
  echo "Installing tc-admin..."
  pip install --quiet --break-system-packages --no-build-isolation -e . > "${PREP_DIR}/pip.log" 2>&1 || {
    cat "${PREP_DIR}/pip.log" >&2
    exit 1
  }

  # Only after installing packages, which needn't see them
  export TASKCLUSTER_ACCESS_TOKEN="${taskcluster_access_token}"
  GITHUB_TOKEN="$(gh auth token)"
  export GITHUB_TOKEN

  if "${BUILD_IMAGES}" && "${UPDATE_TASKCLUSTER_VERSION}"; then
    # The worker-images PR needs someone to review and merge it, so open it
    # before anything else. Only triggering the image builds waits for it to be merged
    # (in rel-sre-imagesets.py below); the steps in between don't depend on it.
    run-step bump-pr with-gpg python3 imagesets/rel-sre-imagesets.py --open-bump-pr
  fi

  # Remember to VNC as administrator onto the macOS workers before running
  # this script, to avoid ssh connection problems!
  # TODO: report if they need to be logged into first with VNC
  if [ "${#pending_macs[@]}" -gt 0 ]; then
    update-macs "${pending_macs[@]}"
  fi

  echo
  echo "Everything that needs you is done: the rest runs unattended."
  echo

  if "${UPDATE_OFFERINGS}"; then
    run-step offerings update-offerings
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
      run-step fxci-pr with-gpg python3 imagesets/rel-sre-imagesets.py --open-fxci-pr
    fi
  fi

  echo "All done!"
}

################## Entry point ##################

IMAGESETS_DIR=/work/imagesets
export OFFICIAL_GIT_REPO='https://github.com/taskcluster/community-tc-config'
: ${IMAGESET_PASSWORD_STORE_URL:=https://source.developers.google.com/p/taskcluster-passwords/r/secrets}

if [ "${#}" -ne 1 ] || ! [[ "${1}" =~ ^(prod|staging|all)$ ]]; then
  echo "Usage: ${0} prod|staging|all (run by imageset.sh)" >&2
  exit 64
fi
export IMAGESET_TARGET="${1}"
set-defaults

PREP_DIR="$(mktemp -d /tmp/imageset.XXXXXXXX)"
STATE_DIR=/state
STEPS_FILE="${STATE_DIR}/${IMAGESET_TARGET}.steps"
# The worker-images runs that rel-sre-imagesets.py waits for
export IMAGESET_RUNS_FILE="${STATE_DIR}/${IMAGESET_TARGET}.runs.json"
CURRENT_STEP=''
RUN_GNUPGHOME=''
HOST_GNUPGHOME=''
VPN_CONNECTED=false
trap 'status=$?; on-exit "${status}"; exit "${status}"' EXIT

if ! "${IMAGESET_RESUME:-false}"; then
  rm -f "${STEPS_FILE}" "${IMAGESET_RUNS_FILE}"
elif [ -f "${STEPS_FILE}" ]; then
  echo "Resuming the previous run: skipping the steps it completed ($(paste -sd , - < "${STEPS_FILE}"))"
fi
deploy-image-sets
