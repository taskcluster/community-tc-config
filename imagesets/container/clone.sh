#!/usr/bin/env bash
# Run by imageset.sh, in its container, before run.sh: clones upstream main
# into /work/community-tc-config, with the files of your checkout (/checkout,
# read-only) if IMAGESET_LOCAL_CHANGES=true, or if they differ from upstream
# main's, and you choose to use them. So git isn't needed on the host.

set -eu
set -o pipefail

OFFICIAL_GIT_REPO='https://github.com/taskcluster/community-tc-config'
CLONE=/work/community-tc-config

# Without your git configuration (the checkout is owned by your user on the
# host, rather than root)
export GIT_CONFIG_GLOBAL=/tmp/gitconfig GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
git config --global --add safe.directory '*'

# The files of the checkout that IMAGESET_LOCAL_CHANGES=true uses, NUL-separated
function checkout-files {
  (
    cd /checkout
    git ls-files -z --cached --others --exclude-standard -- . ':(exclude)config' |
      while IFS= read -r -d '' file; do
        if [ -e "${file}" ]; then
          printf '%s\0' "${file}"
        fi
      done
  )
}

# If IMAGESET_LOCAL_CHANGES isn't set, and the checkout's files differ from
# upstream main's, says so (as upstream main's run), and offers to use them
function offer-local-changes {
  local file
  local changed=()
  local answer
  if [ -n "${IMAGESET_LOCAL_CHANGES}" ]; then
    return
  fi
  IMAGESET_LOCAL_CHANGES=false
  while IFS= read -r -d '' file; do
    cmp -s "/checkout/${file}" "${CLONE}/${file}" || changed+=("${file}")
  done < <(checkout-files)
  if [ "${#changed[@]}" == 0 ]; then
    return
  fi
  echo "These files of your checkout differ from upstream main's, which are the ones that run, unless IMAGESET_LOCAL_CHANGES=true:"
  printf '  %s\n' "${changed[@]}"
  read -r -p "Use your files rather than upstream main's (y/N)? " answer
  case "${answer}" in
    y | Y | yes) IMAGESET_LOCAL_CHANGES=true ;;
  esac
}

echo "Cloning ${OFFICIAL_GIT_REPO} (main)..."
git clone --quiet --branch main "${OFFICIAL_GIT_REPO}" "${CLONE}"
git --no-pager -C "${CLONE}" log -1 --format='Using upstream main at %h: %s'

# A checkout without git (e.g. a downloaded archive) can't have local changes
if git -C /checkout rev-parse --git-dir > /dev/null 2>&1; then
  offer-local-changes
  if "${IMAGESET_LOCAL_CHANGES}"; then
    echo "WARNING: IMAGESET_LOCAL_CHANGES=true: using the files of your checkout (other than config/) rather than upstream main's" >&2
    checkout-files | (cd /checkout && tar -cf - --null -T -) | tar -C "${CLONE}" -xf -
  fi
elif [ "${IMAGESET_LOCAL_CHANGES}" == true ]; then
  echo "IMAGESET_LOCAL_CHANGES=true needs your checkout to be a git clone." >&2
  exit 1
fi
if ! [ -f "${CLONE}/imagesets/container/run.sh" ]; then
  echo "Upstream main's imagesets don't run in a container yet: rerun with IMAGESET_LOCAL_CHANGES=true" >&2
  exit 1
fi

# The files are yours, on the host, with Docker on Linux (see run.sh's on-exit)
if [ "$(stat -c %u /work)" == "${IMAGESET_HOST_UID}" ] && [ "${IMAGESET_HOST_UID}" != 0 ]; then
  chown -R "${IMAGESET_HOST_UID}:${IMAGESET_HOST_GID}" /work
fi
