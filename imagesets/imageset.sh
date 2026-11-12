#!/usr/bin/env bash
# imageset.sh prod|staging|all
#
# Has mozilla-platform-ops/worker-images build image sets, and deploys them
# (see README.md). The work is done by container/run.sh, in a Docker container
# with the tools it needs (container/Dockerfile), from a clone of upstream
# main (by container/clone.sh). This script, on your machine, only needs
# Docker, and:
#
#   - your git name, email and signing key (user.signingkey), from your git
#     configuration, if you have git (otherwise, or to change them, you're
#     asked)
#   - your gpg key, from your gpg home ($GNUPGHOME, or ~/.gnupg), which the
#     container reads (read-only) for the key alone
#   - your browser, which the container has this script open for sign-ins
#
# Progress (for resuming) and your VPN bundle (encrypted to your gpg key) are
# kept in ~/.cache/community-tc-imagesets. A failed run leaves a diagnostic
# log (see diagnostics-README.md) in its diagnostics directory.

set -eu
set -o pipefail

IMAGE=community-tc-imagesets
OFFICIAL_GIT_REPO='https://github.com/taskcluster/community-tc-config'
# Under your home directory, as Docker (e.g. Colima) may only be able to mount that
STATE_DIR="${HOME}/.cache/community-tc-imagesets"
# The settings that are passed to the container (see README.md)
SETTINGS=(BUILD_IMAGES DEPLOY_IMAGES DEPLOY_MACS UPDATE_FXCI_IMAGES UPDATE_OFFERINGS UPDATE_TASKCLUSTER_VERSION
  MAX_RUN_ATTEMPTS IMAGESET_LDAP_USERNAME IMAGESET_PASSWORD_STORE_URL)

function can-open-browser {
  [ -z "${SSH_CONNECTION-}" ] && { [ "$(uname)" == Darwin ] ||
    { { [ -n "${DISPLAY-}" ] || [ -n "${WAYLAND_DISPLAY-}" ]; } && command -v xdg-open > /dev/null; }; }
}

function open-browser {
  if [ "$(uname)" == Darwin ]; then
    open "${1}"
  elif command -v setsid > /dev/null; then
    # In a session of its own, so that a browser it starts isn't hung up when
    # the run (and its terminal) ends
    setsid -f xdg-open "${1}" < /dev/null > /dev/null 2>&1
  else
    # It can stay in the foreground until the browser exits
    xdg-open "${1}" < /dev/null > /dev/null 2>&1 &
  fi
}

function copy-to-clipboard {
  if [ "$(uname)" == Darwin ]; then
    printf '%s' "${1}" | pbcopy
  elif [ -n "${WAYLAND_DISPLAY-}" ] && command -v wl-copy > /dev/null; then
    printf '%s' "${1}" | wl-copy
  elif command -v xclip > /dev/null; then
    printf '%s' "${1}" | xclip -selection clipboard
  elif command -v xsel > /dev/null; then
    printf '%s' "${1}" | xsel --clipboard --input
  else
    return 1
  fi
}

# Opens the URLs that the container's open-url asks for, in your browser, and
# copies their codes to your clipboard, answering with what was done
function bridge {
  local dir="${1}"
  local request
  local url
  local code
  local result
  local answer
  set +e
  while sleep 0.2; do
    for request in "${dir}"/*.request; do
      # The directory is the container's too: symlinks aren't followed
      if [ -L "${request}" ] || ! [ -f "${request}" ] || [ -e "${request%.request}.done" ] || [ -L "${request%.request}.done" ]; then
        continue
      fi
      url=''
      code=''
      # It may have been removed (if open-url gave up waiting)
      { IFS= read -r url; IFS= read -r code; } < "${request}" 2> /dev/null || [ -n "${url}" ] || continue
      result=none
      # Only web pages
      if can-open-browser && [[ "${url}" =~ ^https?:// ]]; then
        result=''
        if [ -n "${code}" ] && copy-to-clipboard "${code}"; then
          result=copied
        fi
        if open-browser "${url}"; then
          result="opened ${result}"
        fi
      fi
      # A new file, renamed into place, so that nothing in the directory is
      # written through
      answer="$(mktemp "${dir}/.answer.XXXXXXXX")"
      echo "${result:-none}" > "${answer}"
      mv -f "${answer}" "${request%.request}.done"
    done
  done
}

function check-docker {
  if ! command -v docker > /dev/null; then
    if [ "$(uname)" == Darwin ]; then
      echo "Docker is needed: e.g. brew install colima docker && colima start (or Docker Desktop)." >&2
    else
      echo "Docker is needed: see https://docs.docker.com/engine/install/" >&2
    fi
    return 1
  fi
  local output
  if ! output="$(docker info 2>&1)"; then
    if [[ "${output}" == *"permission denied"* ]]; then
      echo "You don't have permission to use Docker: add yourself to the docker group (sudo usermod -aG docker \"\${USER}\", then log in again), rather than running imageset.sh with sudo." >&2
    elif [ "$(uname)" == Darwin ]; then
      echo "Docker isn't running (docker info fails): start it, e.g. with colima start." >&2
    else
      echo "Docker isn't running (docker info fails): start it, e.g. with sudo systemctl start docker." >&2
    fi
    return 1
  fi
}

# Your identity, from your git configuration if you have git (read in your
# checkout, for any includeIf), which run.sh asks you to confirm or change, and
# your gpg home
function read-identity {
  IMAGESET_GIT_NAME=''
  IMAGESET_GIT_EMAIL=''
  IMAGESET_GIT_SIGNINGKEY=''
  if command -v git > /dev/null; then
    IMAGESET_GIT_NAME="$(git -C "${CHECKOUT}" config user.name || true)"
    IMAGESET_GIT_EMAIL="$(git -C "${CHECKOUT}" config user.email || true)"
    IMAGESET_GIT_SIGNINGKEY="$(git -C "${CHECKOUT}" config user.signingkey || true)"
  fi
  GNUPG_HOME="${GNUPGHOME:-${HOME}/.gnupg}"
  if ! [ -d "${GNUPG_HOME}/private-keys-v1.d" ]; then
    echo "No gpg secret keys in ${GNUPG_HOME} (set GNUPGHOME, if your gpg home is elsewhere)." >&2
    return 1
  fi
  case "$(cd "${GNUPG_HOME}" && pwd -P)/" in
    "$(cd "${HOME}" && pwd -P)"/*) ;;
    *) echo "WARNING: your gpg home ${GNUPG_HOME} isn't in your home directory, which Docker (e.g. Colima) may not be able to mount." >&2 ;;
  esac
}

# Asks whether to resume an unfinished run of the same target, unless
# IMAGESET_RESUME says
function choose-resume {
  local steps="${STATE_DIR}/${IMAGESET_TARGET}.steps"
  local runs="${STATE_DIR}/${IMAGESET_TARGET}.runs.json"
  local answer
  case "${IMAGESET_RESUME-}" in
    true | false | '') ;;
    *) echo "IMAGESET_RESUME must be true or false" >&2; return 1 ;;
  esac
  if [ -n "${IMAGESET_RESUME-}" ] || ! { [ -f "${steps}" ] || [ -f "${runs}" ] || [ -f "${runs}.started" ]; }; then
    IMAGESET_RESUME="${IMAGESET_RESUME:-false}"
    return
  fi
  echo "A previous ${IMAGESET_TARGET} run didn't finish."
  if [ -f "${steps}" ]; then
    echo "Steps it completed: $(paste -sd , - < "${steps}")"
  fi
  if [ -f "${runs}" ] || [ -f "${runs}.started" ]; then
    echo "It triggered worker-images builds, which resuming waits for, rather than triggering new ones."
  fi
  while true; do
    read -r -p "Resume it (r), or delete its progress and start again (s)? " answer
    case "${answer}" in
      r | R) IMAGESET_RESUME=true; break ;;
      s | S) IMAGESET_RESUME=false; break ;;
    esac
  done
}

# A short hash of a file
function file-hash {
  if command -v shasum > /dev/null; then
    shasum -a 256 "${1}"
  else
    sha256sum "${1}"
  fi | cut -c1-16
}

# Builds the image, unless it is built already for this week's tools (as they
# are updated each week) and the Dockerfile, as building needs the network
# (to check its base image), even when Docker has cached everything. A build
# that fails with what looks like a transient error is repeated, and if it
# still fails, an existing image of the same Dockerfile (with older tools) is
# used. Old images are removed.
function build-image {
  local context="${1}"
  local tag="${2}"
  local log="${IMAGESET_DIAGNOSTICS}/build-${tag##*:}.log"
  local week
  local hash
  local built
  local attempt
  week="$(date +%G-%V)"
  hash="$(file-hash "${context}/Dockerfile")"
  local same
  built="$(docker image inspect --format '{{index .Config.Labels "org.mozilla.community-tc-imagesets.week"}} {{index .Config.Labels "org.mozilla.community-tc-imagesets.dockerfile"}}' "${tag}" 2> /dev/null || true)"
  if [ "${built}" == "${week} ${hash}" ]; then
    return
  fi
  # e.g. the other tag's image (of your checkout's Dockerfile, and upstream
  # main's), if they are the same
  same="$(docker images --quiet --filter "label=org.mozilla.community-tc-imagesets.week=${week}" \
    --filter "label=org.mozilla.community-tc-imagesets.dockerfile=${hash}" | head -1)"
  if [ -n "${same}" ]; then
    docker tag "${same}" "${tag}"
    return
  fi
  echo "Building the container image, with this week's tools (this takes a few minutes, once a week)..."
  local options=()
  # Only BuildKit (buildx) has it: e.g. Ubuntu's docker.io doesn't, and its
  # legacy builder's output is plain anyway
  if docker buildx version > /dev/null 2>&1; then
    options+=(--progress=plain)
  fi
  for attempt in 1 2 3 4 5; do
    if docker build ${options[@]+"${options[@]}"} --build-arg "TOOLS_WEEK=${week}" --label "org.mozilla.community-tc-imagesets.week=${week}" \
      --label "org.mozilla.community-tc-imagesets.dockerfile=${hash}" -t "${tag}" "${context}" > "${log}" 2>&1; then
      docker image prune --force --filter label=org.mozilla.community-tc-imagesets=true > /dev/null 2>&1 || true
      # Each week's build adds a few GB of build cache, which nothing else
      # removes. Build cache has no labels, so this is all of it (of any
      # project) that is older than two weeks, which is rebuilt if needed.
      docker builder prune --force --filter until=336h > /dev/null 2>&1 || true
      return
    fi
    if [ "${attempt}" == 5 ] || ! grep -qiE 'i/o timeout|lookup .* on|no such host|TLS handshake timeout|connection (reset|refused)|unexpected EOF|temporary failure|5[0-9][0-9] (internal server error|bad gateway|service unavailable|gateway timeout)' "${log}"; then
      break
    fi
    echo "Building the container image failed with what looks like a transient error: trying again in $((attempt * 15))s..." >&2
    sleep $((attempt * 15))
  done
  tail -30 "${log}" >&2
  if [ "${built#* }" == "${hash}" ]; then
    echo "WARNING: building the container image failed (see above), so using the existing one, of the same Dockerfile, with the tools of week ${built%% *}." >&2
    return
  fi
  echo "Building the container image failed: see above." >&2
  return 1
}

# Removes the work directories of runs that were killed before they could
function remove-stale-runs {
  local dir
  local pid
  for dir in "${STATE_DIR}"/run.*; do
    [ -d "${dir}" ] || continue
    pid="$(cat "${dir}/pid" 2> /dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2> /dev/null; then
      continue
    fi
    # Its container may outlive it (e.g. if its terminal was closed)
    docker rm --force "imageset-${dir##*/}" > /dev/null 2>&1 || true
    remove-dir "${dir}"
  done
}

# A container killed before it could clean up may have left files owned by root
function remove-dir {
  local image
  rm -rf "${1}" 2> /dev/null && return
  # Files that a container (as root) couldn't give back to you, with Docker on
  # Linux, are removed by a container
  for image in "${IMAGE}:latest" "${IMAGE}:checkout"; do
    if docker run --rm --pull never --security-opt label=disable --volume "$(dirname "${1}"):/parent" "${image}" \
      rm -rf "/parent/$(basename "${1}")" > /dev/null 2>&1 && ! [ -e "${1}" ]; then
      return
    fi
  done
  echo "WARNING: couldn't remove ${1} (e.g. sudo rm -rf it)" >&2
}

# Only one run of a target at a time: a second would use (and could delete)
# the first's progress, and trigger its builds again
function lock-target {
  local lock="${STATE_DIR}/${IMAGESET_TARGET}.lock"
  local pid
  if ! mkdir "${lock}" 2> /dev/null; then
    pid="$(cat "${lock}/pid" 2> /dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2> /dev/null; then
      echo "Another ${IMAGESET_TARGET} run of imageset.sh is in progress (process ${pid}): wait for it to finish, or stop it." >&2
      exit 64
    fi
    # Left by a run that was killed
    rm -rf "${lock}"
    mkdir "${lock}"
  fi
  echo $$ > "${lock}/pid"
  LOCK="${lock}"
}

function cleanup {
  if [ -n "${LOCK}" ]; then
    rm -rf "${LOCK}"
  fi
  if [ -n "${BRIDGE_PID}" ]; then
    kill "${BRIDGE_PID}" 2> /dev/null || true
  fi
  if [ -n "${WORK}" ]; then
    # Without a terminal (e.g. if it was closed), the container would carry on, without its files
    docker rm --force "imageset-${WORK##*/}" > /dev/null 2>&1 || true
    remove-dir "${WORK}"
  fi
}

# Checks the settings' values, which run.sh would otherwise only check after
# the slow image builds
function check-settings {
  local setting
  for setting in BUILD_IMAGES DEPLOY_IMAGES UPDATE_TASKCLUSTER_VERSION UPDATE_FXCI_IMAGES DEPLOY_MACS UPDATE_OFFERINGS \
    IMAGESET_LOCAL_CHANGES IMAGESET_RESUME IMAGESET_KEEP_DIAGNOSTICS; do
    case "${!setting-}" in
      true | false | '') ;;
      *) echo "${setting} must be true or false, rather than '${!setting}'" >&2; exit 64 ;;
    esac
  done
  if [ -n "${MAX_RUN_ATTEMPTS-}" ] && ! [[ "${MAX_RUN_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "MAX_RUN_ATTEMPTS must be a positive number, rather than '${MAX_RUN_ATTEMPTS}'" >&2
    exit 64
  fi
}

# With IMAGESET_LOCAL_CHANGES=true, refuses (before the slow image builds, if
# you have git) what clone.sh would: a checkout without upstream main's latest
# commit, or with changes to config/
function check-local-changes {
  local upstream
  local changes
  if [ "${IMAGESET_LOCAL_CHANGES-}" != true ] || ! command -v git > /dev/null ||
    ! git -C "${CHECKOUT}" rev-parse --git-dir > /dev/null 2>&1; then
    return
  fi
  # If upstream can't be reached, clone.sh checks
  upstream="$(git ls-remote "${OFFICIAL_GIT_REPO}" refs/heads/main 2> /dev/null | cut -f1)"
  [ -n "${upstream}" ] || return 0
  if ! git -C "${CHECKOUT}" merge-base --is-ancestor "${upstream}" HEAD 2> /dev/null; then
    echo "Your checkout doesn't have upstream main's latest commit (${upstream:0:8}), so IMAGESET_LOCAL_CHANGES=true would run its older files too: update it from upstream main (e.g. git pull ${OFFICIAL_GIT_REPO} main), and rerun." >&2
    exit 64
  fi
  changes="$({
    git -C "${CHECKOUT}" diff --name-only "${upstream}" -- config
    git -C "${CHECKOUT}" ls-files --others --exclude-standard -- config
  } | sort -u)"
  if [ -n "${changes}" ]; then
    echo "Your checkout changes config/ (the deployment's configuration, which the run applies with tc-admin apply, and commits to main):" >&2
    echo "${changes}" | sed 's/^/  /' >&2
    echo "imageset.sh doesn't run with local changes to config/: land them on upstream main first (with a pull request, or by pushing to main), or revert them, and rerun." >&2
    exit 64
  fi
}

# What the diagnostic log says about the run, and the host
function write-context {
  local setting
  echo "Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Command: imageset.sh ${IMAGESET_TARGET}"
  echo "Host: $(uname -srm)"
  if [ "$(uname)" == Darwin ]; then
    echo "macOS: $(sw_vers -productVersion 2> /dev/null)"
  elif [ -f /etc/os-release ]; then
    echo "OS: $(. /etc/os-release && echo "${PRETTY_NAME-}")"
  fi
  echo "Docker: $(docker version --format 'client {{.Client.Version}}, server {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})' 2>&1)"
  echo "Docker host: $(docker info --format '{{.OperatingSystem}}, {{.NCPU}} CPUs, {{.MemTotal}} bytes of memory' 2>&1)"
  echo "Settings:"
  for setting in "${SETTINGS[@]}" IMAGESET_LOCAL_CHANGES IMAGESET_RESUME IMAGESET_KEEP_DIAGNOSTICS; do
    if [ -n "${!setting+set}" ]; then
      # Without any credentials in URLs
      echo "  ${setting}=${!setting}" | sed -E 's|://[^/@]+@|://<redacted>@|'
    fi
  done
  if command -v git > /dev/null && git -C "${CHECKOUT}" rev-parse HEAD > /dev/null 2>&1; then
    echo "Checkout: $(git -C "${CHECKOUT}" log -1 --format='%H (%s)') on branch $(git -C "${CHECKOUT}" branch --show-current)"
    echo "Checkout's local changes:"
    git -C "${CHECKOUT}" status --short | sed 's/^/  /'
  fi
  if [ -f "${STATE_DIR}/${IMAGESET_TARGET}.steps" ]; then
    echo "Steps completed by a previous run: $(paste -sd , - < "${STATE_DIR}/${IMAGESET_TARGET}.steps")"
  fi
}

# The terminal transcript as it was shown: without escape sequences, and with
# overwritten lines (\r) and backspaces applied
function clean-transcript {
  if command -v perl > /dev/null; then
    perl -pe 's/\e\][^\a\e]*(?:\a|\e\\)//g; s/\e\[[0-?]*[ -\/]*[@-~]//g; s/\e[ -\/]*[0-~]//g;
      1 while s/[^\x08\n]\x08//; s/[^\r\n]*\r(?=[^\r\n])//g; s/[\x00-\x08\x0b-\x1f\x7f]//g' "${1}"
  else
    cat "${1}"
  fi
}

# Succeeds if the file is a file of the diagnostics directory, rather than a
# symlink (which the container could make) to elsewhere
function diagnostic-file {
  [ -f "${1}" ] && ! [ -L "${1}" ] && ! [ -L "$(dirname "${1}")" ]
}

# Writes the diagnostic log, from the files of the run's diagnostics directory
function write-diagnostic-log {
  local dir="${IMAGESET_DIAGNOSTICS}"
  local file
  cat "${CHECKOUT}/imagesets/diagnostics-README.md"
  for file in "${dir}"/{context.txt,container.txt,build-checkout.log,build-latest.log} "${dir}"/logs/* "${dir}/browser/actions.log"; do
    if diagnostic-file "${file}"; then
      printf '\n===== %s =====\n\n' "${file#"${dir}/"}"
      cat "${file}"
    fi
  done
  if diagnostic-file "${dir}/transcript.raw"; then
    printf '\n===== transcript =====\n\n'
    clean-transcript "${dir}/transcript.raw"
  fi
  for file in "${dir}"/browser/*.txt; do
    if diagnostic-file "${file}" && diagnostic-file "${file%.txt}.html"; then
      printf '\n===== browser/%s =====\n\n' "${file##*/}"
      cat "${file}"
      printf '\n===== browser/%s =====\n\n' "$(basename "${file}" .txt).html"
      cat "${file%.txt}.html"
    fi
  done
}

# Runs imageset.sh again, recorded by script, with a diagnostics directory;
# then deletes it if the run succeeded (unless IMAGESET_KEEP_DIAGNOSTICS=true),
# or writes the diagnostic log from it, and exits with the run's status
function run-with-diagnostics {
  local status=0
  local file
  mkdir -p -m 700 "${STATE_DIR}/diagnostics"
  find "${STATE_DIR}/diagnostics" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} + 2> /dev/null || true
  IMAGESET_DIAGNOSTICS="$(mktemp -d "${STATE_DIR}/diagnostics/run.XXXXXXXX")"
  export IMAGESET_DIAGNOSTICS
  write-context > "${IMAGESET_DIAGNOSTICS}/context.txt" 2>&1 || true
  # So that the log is still written if the terminal is closed, or this is killed
  trap : HUP TERM
  if ! command -v script > /dev/null; then
    "${BASH}" "${0}" "$@" || status=$?
  elif script --version 2> /dev/null | grep -q util-linux; then
    SHELL=/bin/sh script -q -f -e -c "$(printf '%q ' "${BASH}" "${0}" "$@")" "${IMAGESET_DIAGNOSTICS}/transcript.raw" || status=$?
  elif [ "$(uname)" == Darwin ]; then
    script -q -F "${IMAGESET_DIAGNOSTICS}/transcript.raw" "${BASH}" "${0}" "$@" || status=$?
  else
    # e.g. BusyBox's: without a transcript
    "${BASH}" "${0}" "$@" || status=$?
  fi
  echo "Exit status: ${status}" >> "${IMAGESET_DIAGNOSTICS}/context.txt"
  if [ "${status}" == 0 ] && [ "${IMAGESET_KEEP_DIAGNOSTICS-}" != true ]; then
    remove-dir "${IMAGESET_DIAGNOSTICS}"
    exit 0
  fi
  file="${STATE_DIR}/diagnostics/imageset-${IMAGESET_TARGET}-$(date +%Y%m%d-%H%M%S).log"
  if ! (umask 077 && write-diagnostic-log > "${file}"); then
    echo "WARNING: couldn't write the diagnostic log: its files are in ${IMAGESET_DIAGNOSTICS}" >&2
    exit "${status}"
  fi
  remove-dir "${IMAGESET_DIAGNOSTICS}"
  case "${status}" in
    0) echo "Diagnostic log: ${file}" ;;
    # Interrupted, or invalid settings
    64 | 129 | 130 | 143) printf '\nDiagnostic log of this run: %s\n' "${file}" >&2 ;;
    *) echo "Please send diagnostic log ${file} to Claude for analysis (your own Claude, or the imageset maintainers')." >&2 ;;
  esac
  exit "${status}"
}

################## Entry point ##################

# All of it in a function, which bash reads in full before running it, and
# calling it on the last line (with exit, so that bash reads no further): a run
# lasts hours, and bash reads a script as it runs it, so a change to this file
# meanwhile (e.g. git pull) would otherwise break the run.
function main {

  # See README.md for the environment variables that control which steps run.
  if [ "${#}" -ne 1 ] || ! [[ "${1}" =~ ^(prod|staging|all)$ ]]; then
    echo "Usage: ${0} prod|staging|all" >&2
    echo "Has mozilla-platform-ops/worker-images build the production image sets (prod), the staging image sets (staging), or both (all), and deploys them; see README.md." >&2
    exit 64
  fi
  IMAGESET_TARGET="${1}"
  CHECKOUT="$(cd "$(dirname "${0}")/.." && pwd)"

  if [ "$(id -u)" == 0 ]; then
    echo "Don't run imageset.sh as root (e.g. with sudo): it uses your own gpg keys, and keeps its state in your home directory." >&2
    exit 64
  fi
  if ! [ -t 0 ] || ! [ -t 1 ]; then
    echo "imageset.sh needs a terminal, for its prompts and sign-ins." >&2
    exit 1
  fi

  check-settings
  check-docker
  if can-open-browser && (exec 3<> /dev/tcp/127.0.0.1/8085) 2> /dev/null; then
    # gcloud's sign-in sends your browser to http://localhost:8085/
    echo "Port 8085 is in use, but gcloud's sign-in needs it: stop what is using it (e.g. another gcloud auth login)." >&2
    exit 64
  fi
  # Once (rather than again, recorded)
  if [ -z "${IMAGESET_DIAGNOSTICS-}" ]; then
    check-local-changes
  fi

  mkdir -p -m 700 "${STATE_DIR}"
  if [ -L "${STATE_DIR}" ] || ! [ -O "${STATE_DIR}" ]; then
    echo "${STATE_DIR} isn't a directory of yours" >&2
    exit 1
  fi
  chmod 700 "${STATE_DIR}"
  if [ -z "${IMAGESET_DIAGNOSTICS-}" ]; then
    run-with-diagnostics "$@"
  fi

  read-identity
  LOCK=''
  WORK=''
  BRIDGE_PID=''
  trap 'status=$?; cleanup; exit "${status}"' EXIT
  # So that the EXIT trap runs
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  lock-target
  choose-resume

  remove-stale-runs
  WORK="$(mktemp -d "${STATE_DIR}/run.XXXXXXXX")"
  echo $$ > "${WORK}/pid"

  # The image of your checkout clones upstream main (with your changes, if you
  # choose), and then upstream main's image runs it. They are usually the same,
  # so the second build is cached.
  build-image "${CHECKOUT}/imagesets/container" "${IMAGE}:checkout"
  mkdir "${WORK}/clone"
  clone_options=()
  # Your global gitignore, which git in the container uses too: a copy, as it
  # may be a symlink to where Docker can't mount
  global_gitignore="$(git -C "${CHECKOUT}" config --path core.excludesFile 2> /dev/null ||
    echo "${XDG_CONFIG_HOME:-${HOME}/.config}/git/ignore")"
  if [ -f "${global_gitignore}" ] && cat "${global_gitignore}" > "${WORK}/gitignore"; then
    clone_options+=(--volume "${WORK}/gitignore:/host-gitignore:ro")
  fi
  docker run --rm --interactive --tty --init --name "imageset-${WORK##*/}" --security-opt label=disable \
    --volume "${CHECKOUT}:/checkout:ro" --volume "${WORK}/clone:/work" ${clone_options[@]+"${clone_options[@]}"} \
    --env IMAGESET_LOCAL_CHANGES="${IMAGESET_LOCAL_CHANGES-}" --env IMAGESET_HOST_UID="$(id -u)" --env IMAGESET_HOST_GID="$(id -g)" \
    "${IMAGE}:checkout" bash /checkout/imagesets/container/clone.sh
  build-image "${WORK}/clone/community-tc-config/imagesets/container" "${IMAGE}:latest"

  mkdir -m 700 "${WORK}/bridge"
  bridge "${WORK}/bridge" &
  BRIDGE_PID=$!

  docker_options=(
    --rm --interactive --tty --init --name "imageset-${WORK##*/}"
    # Otherwise SELinux (e.g. on Fedora) denies access to the mounts
    --security-opt label=disable
    # For openvpn
    --cap-add NET_ADMIN --device /dev/net/tun
    --volume "${WORK}/clone/community-tc-config:/work"
    --volume "${STATE_DIR}:/state"
    --volume "${WORK}/bridge:/bridge"
    --volume "${IMAGESET_DIAGNOSTICS}:/diagnostics"
    --env IMAGESET_DIAGNOSTICS_DIR=/diagnostics
    --volume "${GNUPG_HOME}:/host-gnupg:ro"
    --env IMAGESET_GIT_NAME="${IMAGESET_GIT_NAME}"
    --env IMAGESET_GIT_EMAIL="${IMAGESET_GIT_EMAIL}"
    --env IMAGESET_GIT_SIGNINGKEY="${IMAGESET_GIT_SIGNINGKEY}"
    --env IMAGESET_GNUPG_HOME_ON_HOST="${GNUPG_HOME}"
    --env IMAGESET_STATE_DIR_ON_HOST="${STATE_DIR}"
    --env IMAGESET_RESUME="${IMAGESET_RESUME}"
    --env IMAGESET_HOST_UID="$(id -u)"
    --env IMAGESET_HOST_GID="$(id -g)"
  )
  if can-open-browser; then
    docker_options+=(--publish 127.0.0.1:8085:8085 --env IMAGESET_HOST_BROWSER=true)
  else
    docker_options+=(--env IMAGESET_HOST_BROWSER=false)
  fi
  for setting in "${SETTINGS[@]}"; do
    if [ -n "${!setting+set}" ]; then
      docker_options+=(--env "${setting}=${!setting}")
    fi
  done

  status=0
  docker run "${docker_options[@]}" "${IMAGE}:latest" /work/imagesets/container/run.sh "${IMAGESET_TARGET}" || status=$?
  exit "${status}"
}

main "$@"; exit
