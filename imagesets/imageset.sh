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
# kept in ~/.cache/community-tc-imagesets.

set -eu
set -o pipefail

IMAGE=community-tc-imagesets
# Under your home directory, as Docker (e.g. Colima) may only be able to mount that
STATE_DIR="${HOME}/.cache/community-tc-imagesets"
# The settings that are passed to the container (see README.md)
SETTINGS=(BUILD_IMAGES DEPLOY_IMAGES DEPLOY_MACS UPDATE_FXCI_IMAGES UPDATE_OFFERINGS UPDATE_TASKCLUSTER_VERSION
  MAX_RUN_ATTEMPTS IMAGESET_LDAP_USERNAME IMAGESET_PASSWORD_STORE_URL)

function can-open-browser {
  [ -z "${SSH_CONNECTION-}" ] && { [ "$(uname)" == Darwin ] || [ -n "${DISPLAY-}" ] || [ -n "${WAYLAND_DISPLAY-}" ]; }
}

function open-browser {
  if [ "$(uname)" == Darwin ]; then
    open "${1}"
  else
    # It can stay in the foreground until the browser exits
    xdg-open "${1}" > /dev/null 2>&1 &
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
  if ! docker info > /dev/null 2>&1; then
    echo "Docker isn't running (docker info fails): start it, e.g. with colima start." >&2
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
  local log="${WORK}/build.log"
  local week
  local hash
  local built
  local attempt
  week="$(date +%G-%V)"
  hash="$(file-hash "${context}/Dockerfile")"
  local tag="${2}"
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
  for attempt in 1 2 3 4 5; do
    if docker build --progress=plain --build-arg "TOOLS_WEEK=${week}" --label "org.mozilla.community-tc-imagesets.week=${week}" \
      --label "org.mozilla.community-tc-imagesets.dockerfile=${hash}" -t "${tag}" "${context}" > "${log}" 2>&1; then
      docker image prune --force --filter label=org.mozilla.community-tc-imagesets=true > /dev/null 2>&1 || true
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
  rm -rf "${1}" 2> /dev/null || echo "WARNING: couldn't remove ${1} (e.g. sudo rm -rf it)" >&2
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
      exit 1
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

  if ! [ -t 0 ] || ! [ -t 1 ]; then
    echo "imageset.sh needs a terminal, for its prompts and sign-ins." >&2
    exit 1
  fi

  check-docker
  read-identity

  mkdir -p -m 700 "${STATE_DIR}"
  if [ -L "${STATE_DIR}" ] || ! [ -O "${STATE_DIR}" ]; then
    echo "${STATE_DIR} isn't a directory of yours" >&2
    exit 1
  fi
  chmod 700 "${STATE_DIR}"
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
  case "${IMAGESET_LOCAL_CHANGES-}" in
    true | false | '') ;;
    *) echo "IMAGESET_LOCAL_CHANGES must be true or false" >&2; exit 64 ;;
  esac

  # The image of your checkout clones upstream main (with your changes, if you
  # choose), and then upstream main's image runs it. They are usually the same,
  # so the second build is cached.
  build-image "${CHECKOUT}/imagesets/container" "${IMAGE}:checkout"
  mkdir "${WORK}/clone"
  docker run --rm --interactive --tty --init --name "imageset-${WORK##*/}" --security-opt label=disable \
    --volume "${CHECKOUT}:/checkout:ro" --volume "${WORK}/clone:/work" \
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
    # gcloud's sign-in sends your browser to http://localhost:8085/
    if (exec 3<> /dev/tcp/127.0.0.1/8085) 2> /dev/null; then
      echo "Port 8085 is in use, but gcloud's sign-in needs it: stop what is using it (e.g. another gcloud auth login)." >&2
      exit 1
    fi
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
