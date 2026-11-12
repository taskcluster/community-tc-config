#!/usr/bin/env bash
# Run by imageset.sh, in its container, before run.sh: clones upstream main
# into /work/community-tc-config, and, if IMAGESET_LOCAL_CHANGES=true (or your
# checkout has changes, and you choose to use them), makes its files those of
# your checkout (/checkout, read-only), with rsync. So git and rsync aren't
# needed on the host. Your checkout must have upstream main's latest commit,
# so that only your changes differ from it, and mustn't change config/ (the
# deployment's configuration, which the run applies with tc-admin apply, and
# commits to), which is always upstream main's.

set -eu
set -o pipefail

OFFICIAL_GIT_REPO='https://github.com/taskcluster/community-tc-config'
CHECKOUT=/checkout
CLONE=/work/community-tc-config
# Your global gitignore (core.excludesFile), from imageset.sh, if you have one
HOST_GITIGNORE=/host-gitignore

# Makes the clone's files those of the checkout (its tracked files, and its
# untracked files that git doesn't ignore), other than config/, keeping the
# clone's .git. With --dry-run, lists what that would change instead.
function sync-checkout {
  local ignored
  ignored="$(mktemp)"
  # As rsync patterns, anchored, with their wildcard characters escaped
  git -C "${CHECKOUT}" ls-files -z --others --ignored --exclude-standard --directory |
    tr '\0' '\n' | sed -e 's/[][*?\\]/\\&/g' -e 's|^|/|' > "${ignored}"
  rsync --recursive --links --perms --checksum --delete --itemize-changes --out-format='%i %n' \
    --exclude=/.git --exclude=/config/ --exclude-from="${ignored}" "$@" "${CHECKOUT}/" "${CLONE}/" |
    # Files and symlinks, rather than directories
    awk '$1 == "*deleting" && $2 !~ /\/$/ { print "  " substr($0, index($0, $2)) " (deleted)" }
      $1 != "*deleting" && substr($1, 2, 1) != "d" { print "  " substr($0, index($0, $2)) }'
  rm -f "${ignored}"
}

# Succeeds if the checkout has upstream main's latest commit (the clone's)
function checkout-has-upstream {
  git -C "${CHECKOUT}" merge-base --is-ancestor "$(git -C "${CLONE}" rev-parse HEAD)" HEAD 2> /dev/null
}

# Succeeds if the checkout has changes of its own: commits that upstream main
# doesn't have, or uncommitted changes (other than to config/)
function has-local-changes {
  ! git -C "${CLONE}" merge-base --is-ancestor "$(git -C "${CHECKOUT}" rev-parse HEAD)" HEAD 2> /dev/null ||
    [ -n "$(git -C "${CHECKOUT}" --no-optional-locks status --porcelain -- . ':(exclude)config')" ]
}

# The files of config/ that differ from upstream main's, in a checkout that
# has upstream main's latest commit (committed, uncommitted or untracked)
function local-config-changes {
  {
    git -C "${CHECKOUT}" diff --name-only "$(git -C "${CLONE}" rev-parse HEAD)" -- config
    git -C "${CHECKOUT}" ls-files --others --exclude-standard -- config
  } | sort -u
}

# Decides whether to use the checkout's files (IMAGESET_LOCAL_CHANGES), asking
# if it isn't set, and the checkout has changes; refuses a checkout without
# upstream main's latest commit, or with changes to config/
function choose-local-changes {
  local answer
  local changes
  local config_changes
  if [ "${IMAGESET_LOCAL_CHANGES}" == false ]; then
    return
  fi
  if ! checkout-has-upstream; then
    if [ "${IMAGESET_LOCAL_CHANGES}" == true ]; then
      echo "Your checkout doesn't have upstream main's latest commit, so IMAGESET_LOCAL_CHANGES=true would run its older files too: update it from upstream main (e.g. git pull ${OFFICIAL_GIT_REPO} main), and rerun." >&2
      exit 64
    fi
    if has-local-changes; then
      echo "Your checkout has changes, but not upstream main's latest commit, so upstream main's files run: to run your changes, update it from upstream main (e.g. git pull ${OFFICIAL_GIT_REPO} main), and rerun."
    fi
    IMAGESET_LOCAL_CHANGES=false
    return
  fi
  changes="$(sync-checkout --dry-run)"
  if [ -z "${IMAGESET_LOCAL_CHANGES}" ]; then
    IMAGESET_LOCAL_CHANGES=false
    if [ -z "${changes}" ]; then
      return
    fi
    echo "Your checkout changes these files, which only run if IMAGESET_LOCAL_CHANGES=true (otherwise upstream main's do):"
    echo "${changes}"
    read -r -p "Use your changes (y/N)? " answer
    case "${answer}" in
      y | Y | yes) IMAGESET_LOCAL_CHANGES=true ;;
      *) return ;;
    esac
  fi
  config_changes="$(local-config-changes)"
  if [ -n "${config_changes}" ]; then
    echo "Your checkout changes config/ (the deployment's configuration, which the run applies with tc-admin apply, and commits to main):" >&2
    echo "${config_changes}" | sed 's/^/  /' >&2
    echo "imageset.sh doesn't run with local changes to config/: land them on upstream main first (with a pull request, or by pushing to main), or revert them, and rerun." >&2
    exit 64
  fi
  if [ -n "${changes}" ]; then
    echo "WARNING: IMAGESET_LOCAL_CHANGES=true: using your checkout's changes:" >&2
    echo "${changes}" >&2
    sync-checkout > /dev/null
  fi
}

# The files are yours, on the host, with Docker on Linux (see run.sh's on-exit)
function give-back-files {
  local work
  work="$(dirname "${CLONE}")"
  if [ "$(stat -c %u "${work}")" == "${IMAGESET_HOST_UID}" ] && [ "${IMAGESET_HOST_UID}" != 0 ]; then
    chown -R "${IMAGESET_HOST_UID}:${IMAGESET_HOST_GID}" "${work}" 2> /dev/null || true
  fi
}

function main {
  trap give-back-files EXIT
  # So that the EXIT trap runs
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Without your git configuration (the checkout is owned by your user on the
  # host, rather than root), other than your global gitignore
  export GIT_CONFIG_GLOBAL=/tmp/gitconfig GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  git config --global --add safe.directory '*'
  if [ -f "${HOST_GITIGNORE}" ]; then
    git config --global core.excludesFile "${HOST_GITIGNORE}"
  fi

  echo "Cloning ${OFFICIAL_GIT_REPO} (main)..."
  git clone --quiet --branch main "${OFFICIAL_GIT_REPO}" "${CLONE}"
  git --no-pager -C "${CLONE}" log -1 --format='Using upstream main at %h: %s'

  # A checkout without git (e.g. a downloaded archive) can't have local changes
  if git -C "${CHECKOUT}" rev-parse --git-dir > /dev/null 2>&1; then
    choose-local-changes
  elif [ "${IMAGESET_LOCAL_CHANGES}" == true ]; then
    echo "IMAGESET_LOCAL_CHANGES=true needs your checkout to be a git clone." >&2
    exit 64
  fi
  if ! [ -f "${CLONE}/imagesets/container/run.sh" ]; then
    echo "Upstream main's imagesets don't run in a container yet: rerun with IMAGESET_LOCAL_CHANGES=true" >&2
    exit 1
  fi
}

# Unless sourced (by test_clone.py)
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  main "$@"
fi
