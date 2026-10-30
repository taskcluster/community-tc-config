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
      cmp) package=diffutils ;;
      gpg) package=gnupg ;;
      ssh) package=openssh-client ;;
      *) package=coreutils ;;
    esac
    echo "sudo apt-get install ${package}"
  elif command -v dnf > /dev/null; then
    case "${tool}" in
      curl | git | pass | python3 | tar) package="${tool}" ;;
      cmp) package=diffutils ;;
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
  local tools=(awk az cat chmod cmp cp dirname env gcloud gh git gpg gpg-connect-agent gpgconf grep id mkdir mktemp pass paste python3 rm sed sleep tar tee tr uname)
  local tool
  local missing=false
  local version
  if "${DEPLOY_MACS}"; then
    tools+=(base64 seq ssh)
  fi
  if "${UPDATE_OFFERINGS}"; then
    tools+=(aws curl sort)
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
  if [[ "$(gh auth login --help)" != *--clipboard* ]]; then
    echo "A newer gh is needed, rather than $(gh --version | head -1). To install it: $(install-hint gh)" >&2
    return 1
  fi
  IMAGESET_GNUPG_HOME="$(gpgconf --list-dirs homedir)"
  export IMAGESET_GNUPG_HOME
  IMAGESET_GPG_KEY="$(find-gpg-key)" || return 1
  export IMAGESET_GPG_KEY
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

function open-browser {
  if [ "$(uname)" == Darwin ]; then
    open "${1}"
  else
    xdg-open "${1}" > /dev/null 2>&1
  fi
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

# Connects to a macOS worker with ssh, checking its host key, but doesn't log
# in, so its password isn't needed. Outputs ssh's errors. A reachable worker
# rejects the (non-existent) password, with "Permission denied".
function mac-ssh-probe {
  local host="${1}"
  mac-ssh-options
  # Before MAC_SSH_OPTIONS, as ssh uses the first value of each option
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${MAC_SSH_OPTIONS[@]}" -n "administrator@${host}" true 2>&1
}

function have-viscosity {
  [ "$(uname)" == Darwin ] && open -Ra Viscosity 2> /dev/null
}

# The names of Viscosity's connections, one per line
function viscosity-connections {
  osascript << 'EOF'
tell application "Viscosity" to set names to name of connections
set AppleScript's text item delimiters to linefeed
names as text
EOF
}

function viscosity-connected-count {
  osascript -e 'tell application "Viscosity" to count (connections whose state is "Connected")'
}

function viscosity-connect {
  echo "Connecting ${1} with Viscosity: complete its sign-in."
  osascript -e 'on run argv' -e 'tell application "Viscosity" to connect (item 1 of argv)' -e 'end run' "${1}" > /dev/null ||
    echo "Couldn't have Viscosity connect ${1}: connect it with Viscosity yourself." >&2
}

# Explains why the macOS workers can't be reached, and on macOS, connects to
# the VPN with Viscosity, if it has one connection and none is connected. Sets
# VPN_CHOICES to the connections that the user can choose from by number.
function suggest-vpn {
  local connected
  local name
  local i
  VPN_CHOICES=()
  if ! have-viscosity; then
    echo "The macOS workers are only reachable through the Mozilla corporate VPN: connect to it with Viscosity. If you are connected already, they may be rebooting."
    return
  fi
  if ! connected="$(viscosity-connected-count 2> /dev/null)"; then
    echo "The macOS workers are only reachable through the Mozilla corporate VPN: connect to it with Viscosity (allowing your terminal to control Viscosity would let imageset.sh connect it)."
    return
  fi
  if [ "${connected}" != 0 ]; then
    echo "Viscosity is connected, so the macOS workers may be rebooting, or the VPN connection doesn't route to them (if so, connect another one with Viscosity)."
    return
  fi
  echo "The macOS workers are only reachable through the Mozilla corporate VPN, which Viscosity isn't connected to."
  while IFS= read -r name; do
    if [ -n "${name}" ]; then
      VPN_CHOICES+=("${name}")
    fi
  done < <(viscosity-connections 2> /dev/null || true)
  case "${#VPN_CHOICES[@]}" in
    0)
      echo "Viscosity has no connections: add the Mozilla corporate VPN to it, and connect."
      ;;
    1)
      viscosity-connect "${VPN_CHOICES[0]}"
      VPN_CHOICES=()
      ;;
    *)
      if [ -t 0 ]; then
        echo "Enter the number of the connection to connect with Viscosity (or connect with Viscosity yourself):"
        for i in "${!VPN_CHOICES[@]}"; do
          echo "  $((i + 1))) ${VPN_CHOICES[i]}"
        done
      else
        echo "Connect to it with Viscosity."
        VPN_CHOICES=()
      fi
      ;;
  esac
}

# Waits until each macOS worker accepts ssh connections. This runs before the
# sign-ins (and their 2FA), so that being off the VPN doesn't mean signing in
# again after connecting. The passwords are checked later, once the password
# store has been read, by check-mac-connectivity.
function wait-for-macs {
  local host
  local output
  local last_output
  local status
  local unreachable
  local waiting=false
  local answer
  VPN_CHOICES=()
  while true; do
    unreachable=()
    for host in "$@"; do
      status=0
      output="$(mac-ssh-probe "${host}")" || status=$?
      if [ "${status}" == 0 ] || [[ "${output}" == *"Permission denied"* ]]; then
        continue
      fi
      if [[ "${output}" == *"Host key verification failed"* ]]; then
        echo "The host key of ${host} isn't in ${IMAGESETS_DIR}/mac_known_hosts: if the worker was reinstalled, update it (ssh-keyscan -t ed25519 <host>), or rerun with DEPLOY_MACS=false to skip the macOS workers." >&2
        return 1
      fi
      unreachable+=("${host}")
      last_output="${output}"
    done
    if [ "${#unreachable[@]}" == 0 ]; then
      if "${waiting}"; then
        echo "The macOS workers are reachable: continuing."
      fi
      return 0
    fi
    if ! "${waiting}"; then
      waiting=true
      echo
      echo "Can't connect to ${unreachable[*]} with ssh: ${last_output}"
      suggest-vpn
      echo "Waiting until they are reachable (or press Ctrl-C to stop, and rerun with DEPLOY_MACS=false to skip the macOS workers)..."
    fi
    if [ "${#VPN_CHOICES[@]}" -gt 0 ]; then
      answer=''
      read -r -t 5 answer || true
      if [[ "${answer}" =~ ^[0-9]+$ ]] && [ "${answer}" -ge 1 ] && [ "${answer}" -le "${#VPN_CHOICES[@]}" ]; then
        viscosity-connect "${VPN_CHOICES[answer - 1]}"
      elif [ -n "${answer}" ]; then
        echo "Enter a number from 1 to ${#VPN_CHOICES[@]}."
      fi
    else
      sleep 5
    fi
  done
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
  # Whatever your own settings, with the wrapper of setup-gpg
  git config --global commit.gpgsign true
  git config --global tag.gpgsign true
  git config --global gpg.format openpgp
  git config --global user.signingkey "${IMAGESET_GPG_KEY}"
  git config --global gpg.program "${PREP_DIR}/bin/gpg"
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
  key="$(git -C "${IMAGESETS_DIR}" config user.signingkey || true)"
  key="${key%!}"
  key="${key:-<${IMAGESET_GIT_EMAIL}>}"
  # Keys that can sign and encrypt (uppercase capabilities are the usable ones)
  fprs="$(gpg --batch --with-colons --list-secret-keys -- "${key}" 2> /dev/null |
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
# with a copy of the key (IMAGESET_GPG_KEY), so that a passphrase cached by
# your own agent or keychain isn't used. The agent caches nothing, so nothing
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
  printf 'default-cache-ttl 0\nmax-cache-ttl 0\nallow-loopback-pinentry\nno-allow-external-cache\ndisable-scdaemon\npinentry-program %s\n' "$(command -v false)" > "${GNUPGHOME}/gpg-agent.conf"
  GNUPGHOME="${IMAGESET_GNUPG_HOME}" "${real_gpg}" --batch --export "${IMAGESET_GPG_KEY}" |
    "${real_gpg}" --batch --quiet --import
  # The private key files are encrypted with the passphrase
  mkdir -p -m 700 "${GNUPGHOME}/private-keys-v1.d"
  for grip in $(GNUPGHOME="${IMAGESET_GNUPG_HOME}" "${real_gpg}" --batch --with-colons --with-keygrip --list-secret-keys "${IMAGESET_GPG_KEY}" | awk -F: '$1 == "grp" { print $10 }'); do
    if [ -f "${IMAGESET_GNUPG_HOME}/private-keys-v1.d/${grip}.key" ]; then
      cp "${IMAGESET_GNUPG_HOME}/private-keys-v1.d/${grip}.key" "${GNUPGHOME}/private-keys-v1.d/"
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
    echo "No private key of ${IMAGESET_GPG_KEY} in ${IMAGESET_GNUPG_HOME}/private-keys-v1.d" >&2
    return 1
  fi

  mkdir -p "${bin}"
  for name in gpg gpg2; do
    cat > "${bin}/${name}" << EOF
#!/bin/sh
# With the passphrase from imageset.sh's with-gpg, if the key has one
if { : <&7; } 2> /dev/null; then
  exec '${real_gpg}' --batch --pinentry-mode loopback --passphrase-fd 7 "\$@"
fi
exec '${real_gpg}' --batch --pinentry-mode error "\$@"
EOF
    chmod 755 "${bin}/${name}"
  done
  export PATH="${bin}:${PATH}"

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
  uid="$(gpg --with-colons --list-keys "${IMAGESET_GPG_KEY}" | awk -F: '$1 == "uid" { print $10; exit }')"
  if ! [ -t 0 ]; then
    echo "imageset.sh needs a terminal, to ask for the passphrase of your gpg key." >&2
    return 1
  fi
  while true; do
    IFS= read -r -s -p "Passphrase of your gpg key (${uid}, ${IMAGESET_GPG_KEY}): " GPG_PASSPHRASE
    echo
    if with-gpg check-gpg-key 2> /dev/null; then
      return
    fi
    echo "That passphrase doesn't unlock it: try again (or press Ctrl-C to stop)." >&2
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

# The token is stored in GH_CONFIG_DIR, rather than the user's keychain. As
# prompts are disabled, gh only shows the URL, which is opened here, with the
# code in the clipboard.
function login-github {
  local options=(--hostname github.com --git-protocol https --scopes workflow --insecure-storage --web)
  local line
  local url
  local copied=false
  if ! can-open-browser; then
    gh auth login "${options[@]}"
    return
  fi
  gh auth login "${options[@]}" --clipboard 2>&1 | while IFS= read -r line; do
    case "${line}" in
      *"copied to clipboard"*)
        copied=true
        echo "${line}"
        ;;
      *"to continue in your web browser: https://github.com/"*)
        url="${line##* }"
        if ! open-browser "${url}"; then
          echo "${line}"
        elif "${copied}"; then
          echo "Opened ${url} in your browser: paste the code (from your clipboard) there."
        else
          echo "Opened ${url} in your browser: enter the code above there."
        fi
        ;;
      *) echo "${line}" ;;
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
  if ! with-gpg git pull --quiet --rebase --autostash "${OFFICIAL_GIT_REPO}" main; then
    git rebase --abort 2> /dev/null || true
    return 1
  fi
  check-signed FETCH_HEAD..HEAD
  git push "${OFFICIAL_GIT_REPO}" HEAD:refs/heads/main
}

# The files of the checkout that IMAGESET_LOCAL_CHANGES=true uses, NUL-separated
function checkout-files {
  (
    cd "${1}"
    git ls-files -z --cached --others --exclude-standard -- . ':(exclude)config' |
      while IFS= read -r -d '' file; do
        [ -e "${file}" ] && printf '%s\0' "${file}"
      done
  )
}

# If IMAGESET_LOCAL_CHANGES isn't set, and the checkout's files differ from
# upstream main's, says so (as upstream main's run), and offers to use them
function offer-local-changes {
  local checkout="${1}"
  local clone="${2}"
  local file
  local changed=()
  local answer
  if [ -n "${IMAGESET_LOCAL_CHANGES_SET}" ]; then
    return
  fi
  while IFS= read -r -d '' file; do
    cmp -s "${checkout}/${file}" "${clone}/${file}" || changed+=("${file}")
  done < <(checkout-files "${checkout}")
  if [ "${#changed[@]}" == 0 ]; then
    return
  fi
  echo "These files of ${checkout} differ from upstream main's, which are the ones that run, unless IMAGESET_LOCAL_CHANGES=true:"
  printf '  %s\n' "${changed[@]}"
  if ! [ -t 0 ]; then
    return
  fi
  read -r -p "Use your files rather than upstream main's (y/N)? " answer
  case "${answer}" in
    y | Y | yes) IMAGESET_LOCAL_CHANGES=true ;;
  esac
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
  offer-local-changes "${checkout}" "${clone}"
  if "${IMAGESET_LOCAL_CHANGES}"; then
    echo "WARNING: IMAGESET_LOCAL_CHANGES=true: using the files of ${checkout} (other than config/) rather than upstream main's" >&2
    checkout-files "${checkout}" | (cd "${checkout}" && tar -cf - --null -T -) | tar -C "${clone}" -xf -
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

  setup-gpg

  # Only the macOS workers that a resumed run hasn't updated yet
  local pending_macs=()
  if "${DEPLOY_MACS}"; then
    for HOST in "${MAC_HOSTS[@]}"; do
      step-done "mac ${HOST}" || pending_macs+=("${HOST}")
    done
  fi
  if [ "${#pending_macs[@]}" -gt 0 ]; then
    wait-for-macs "${pending_macs[@]}"
  fi

  if "${UPDATE_GCLOUD}"; then
    retry update-gcloud
  fi
  if can-open-browser; then
    retry gcloud auth login
  else
    retry gcloud auth login --no-launch-browser
  fi

  login-github

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
    run-step bump-pr with-gpg python3 imagesets/rel-sre-imagesets.py --open-bump-pr
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
  # The macOS workers are checked to be reachable (e.g. that the VPN is
  # connected) before the sign-ins, and ssh as administrator after reading
  # their passwords.
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
      run-step fxci-pr with-gpg python3 imagesets/rel-sre-imagesets.py --open-fxci-pr
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

# Whether the user chose, rather than set-defaults
IMAGESET_LOCAL_CHANGES_SET="${IMAGESET_LOCAL_CHANGES+set}"
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

STEPS_FILE=''
IMAGESET_RUNS_FILE=''
CURRENT_STEP=''
RUN_GNUPGHOME=''
trap 'status=$?; cd; stop-gpg; rm -rf "${PREP_DIR}"; finish "${status}"; exit "${status}"' EXIT

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
