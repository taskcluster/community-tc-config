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
  set +e
  while sleep 0.2; do
    for request in "${dir}"/*.request; do
      if ! [ -f "${request}" ] || [ -e "${request%.request}.done" ]; then
        continue
      fi
      { IFS= read -r url; IFS= read -r code; } < "${request}"
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
      echo "${result:-none}" > "${request%.request}.answer"
      mv "${request%.request}.answer" "${request%.request}.done"
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

# Builds the image, which Docker caches, other than the tools, which are
# updated each week. Old images are removed.
function build-image {
  local context="${1}"
  local log="${WORK}/build.log"
  local week
  week="$(date +%G-%V)"
  if ! docker image inspect --format '{{index .Config.Labels "org.mozilla.community-tc-imagesets.week"}}' "${IMAGE}" 2> /dev/null | grep -qx "${week}"; then
    echo "Building the container image, with this week's tools (this takes a few minutes, once a week)..."
  fi
  if ! docker build --progress=plain --build-arg "TOOLS_WEEK=${week}" --label "org.mozilla.community-tc-imagesets.week=${week}" -t "${IMAGE}" "${context}" > "${log}" 2>&1; then
    tail -30 "${log}" >&2
    echo "Building the container image failed: see above." >&2
    return 1
  fi
  docker image prune --force --filter label=org.mozilla.community-tc-imagesets=true > /dev/null 2>&1 || true
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

function cleanup {
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
choose-resume

WORK=''
BRIDGE_PID=''
trap 'status=$?; cleanup; exit "${status}"' EXIT
# So that the EXIT trap runs
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
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
build-image "${CHECKOUT}/imagesets/container"
mkdir "${WORK}/clone"
docker run --rm --interactive --tty --init --name "imageset-${WORK##*/}" --security-opt label=disable \
  --volume "${CHECKOUT}:/checkout:ro" --volume "${WORK}/clone:/work" \
  --env IMAGESET_LOCAL_CHANGES="${IMAGESET_LOCAL_CHANGES-}" --env IMAGESET_HOST_UID="$(id -u)" --env IMAGESET_HOST_GID="$(id -g)" \
  "${IMAGE}" bash /checkout/imagesets/container/clone.sh
build-image "${WORK}/clone/community-tc-config/imagesets/container"

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
docker run "${docker_options[@]}" "${IMAGE}" /work/imagesets/container/run.sh "${IMAGESET_TARGET}" || status=$?
exit "${status}"
