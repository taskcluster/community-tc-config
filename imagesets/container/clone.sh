#!/usr/bin/env bash
# Run by imageset.sh, in its container, before run.sh: clones upstream main
# into /work/community-tc-config, and, if IMAGESET_LOCAL_CHANGES=true (or your
# checkout has changes, and you choose to use them), makes its files those of
# your checkout (/checkout, read-only), with rsync. So git and rsync aren't
# needed on the host. config/ (the deployment's configuration, which the run
# applies with tc-admin apply, and commits to) is always upstream main's: the
# run refuses local changes to it.

set -eu
set -o pipefail

OFFICIAL_GIT_REPO='https://github.com/taskcluster/community-tc-config'
CHECKOUT=/checkout
CLONE=/work/community-tc-config

# Makes the clone's files those of the checkout (its tracked files, and its
# untracked files that git doesn't ignore), other than config/, keeping the
# clone's .git. With --dry-run, lists what that would change instead.
function sync-checkout {
  local ignored
  ignored="$(mktemp)"
  git -C "${CHECKOUT}" ls-files -z --others --ignored --exclude-standard --directory | tr '\0' '\n' | sed 's|^|/|' > "${ignored}"
  rsync --recursive --links --perms --checksum --delete --itemize-changes --out-format='%i %n' \
    --exclude=/.git --exclude=/config/ --exclude-from="${ignored}" "$@" "${CHECKOUT}/" "${CLONE}/" |
    # Files and symlinks, rather than directories
    awk '$1 == "*deleting" && $2 !~ /\/$/ { print "  " substr($0, index($0, $2)) " (deleted)" }
      $1 != "*deleting" && substr($1, 2, 1) != "d" { print "  " substr($0, index($0, $2)) }'
  rm -f "${ignored}"
}

# Succeeds if the checkout has changes of its own: commits that upstream main
# doesn't have, or uncommitted changes (other than to config/). A checkout
# that is only behind upstream main has none.
function has-local-changes {
  local head
  head="$(git -C "${CHECKOUT}" rev-parse HEAD)"
  ! git -C "${CLONE}" merge-base --is-ancestor "${head}" HEAD 2> /dev/null ||
    [ -n "$(git -C "${CHECKOUT}" --no-optional-locks status --porcelain -- . ':(exclude)config')" ]
}

# The files of config/ that the checkout changed: in commits that upstream
# main doesn't have (since where they diverged), or uncommitted. Changes that
# the checkout is only behind upstream main for don't count.
function local-config-changes {
  local base
  git -C "${CLONE}" fetch --quiet "${CHECKOUT}" HEAD
  base="$(git -C "${CLONE}" merge-base HEAD FETCH_HEAD)"
  {
    git -C "${CLONE}" diff --name-only "${base}" FETCH_HEAD -- config
    git -C "${CHECKOUT}" --no-optional-locks status --porcelain --untracked-files=all -- config | cut -c4-
  } | sort -u
}

# If IMAGESET_LOCAL_CHANGES isn't set, and the checkout has changes of its
# own, says so (as upstream main's files run), and offers to use them
function offer-local-changes {
  local answer
  if [ -n "${IMAGESET_LOCAL_CHANGES}" ]; then
    return
  fi
  IMAGESET_LOCAL_CHANGES=false
  if ! has-local-changes; then
    return
  fi
  echo "Your checkout differs from upstream main in these files, which only run if IMAGESET_LOCAL_CHANGES=true (otherwise upstream main's do):"
  sync-checkout --dry-run
  read -r -p "Use your checkout's files (y/N)? " answer
  case "${answer}" in
    y | Y | yes) IMAGESET_LOCAL_CHANGES=true ;;
  esac
}

function main {
  # Without your git configuration (the checkout is owned by your user on the
  # host, rather than root)
  export GIT_CONFIG_GLOBAL=/tmp/gitconfig GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  git config --global --add safe.directory '*'

  echo "Cloning ${OFFICIAL_GIT_REPO} (main)..."
  git clone --quiet --branch main "${OFFICIAL_GIT_REPO}" "${CLONE}"
  git --no-pager -C "${CLONE}" log -1 --format='Using upstream main at %h: %s'

  # A checkout without git (e.g. a downloaded archive) can't have local changes
  if git -C "${CHECKOUT}" rev-parse --git-dir > /dev/null 2>&1; then
    offer-local-changes
    if "${IMAGESET_LOCAL_CHANGES}"; then
      config_changes="$(local-config-changes)"
      if [ -n "${config_changes}" ]; then
        echo "Your checkout changes config/ (the deployment's configuration, which the run applies with tc-admin apply, and commits to main):" >&2
        echo "${config_changes}" | sed 's/^/  /' >&2
        echo "imageset.sh doesn't run with local changes to config/: land them on upstream main first (with a pull request, or by pushing to main), or revert them, and rerun." >&2
        exit 1
      fi
      echo "WARNING: IMAGESET_LOCAL_CHANGES=true: using your checkout's files (other than config/), rather than upstream main's:" >&2
      sync-checkout >&2
      if ! git -C "${CHECKOUT}" merge-base --is-ancestor "$(git -C "${CLONE}" rev-parse HEAD)" HEAD 2> /dev/null; then
        echo "WARNING: your checkout doesn't have upstream main's latest commit, so its older files run too: pull (or rebase), to run upstream main's latest, with your changes." >&2
      fi
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
}

# Unless sourced (by test_clone.py)
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  main "$@"
fi
