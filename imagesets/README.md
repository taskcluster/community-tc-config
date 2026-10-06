# Deploying Image Sets

Machine images are not built in this repository: they are built by the TCEng
GitHub Actions workflows of relops'
[worker-images](https://github.com/mozilla-platform-ops/worker-images)
repository. To have worker-images build new images of all image sets, and
deploy them to community-tc's worker pools, run, from this directory:

  * `./imageset.sh all`

This is the only way to run the script; no other arguments are accepted. It
always deploys to AWS, Azure and GCP, and updates the macOS workers. The environment variables [below](#environment-variables) can
skip some of the steps.

## Prerequisites

1) AWS: credentials set up with `aws configure` (or `SIGNIN_AWS_ACCESS_KEY_ID`
   and `SIGNIN_AWS_SECRET_ACCESS_KEY`), with MFA enabled on your AWS account. The
   script signs in with [`signin-aws.sh`](signin-aws.sh), which prompts for an
   MFA code, or reads it from your Yubikey if `SIGNIN_AWS_YUBIKEY_OATH_NAME` is
   set.

2) Azure: `az` installed. The script runs `az login`.

3) GCP: `gcloud` installed. The script runs `gcloud auth login`.

4) GitHub: `gh` installed and logged in (`gh auth login`). It is used to trigger
   the image builds in
   [worker-images](https://github.com/mozilla-platform-ops/worker-images), and
   to open PRs there and in
   [fxci-config](https://github.com/mozilla-releng/fxci-config) (from your fork,
   which is created if you don't have one).

5) A valid git configuration under `~/.gitconfig` with a valid user/email, and
   an ssh key that can push to `git@github.com:taskcluster/community-tc-config`
   and the taskcluster team password store. If the key is not in a standard
   location (e.g. `~/.ssh/id_rsa`, `~/.ssh/id_ed25519`, ...), specify it with an
   `IdentityFile` directive in `~/.ssh/config`.

6) Your gpg account configured under `~/.gnupg`, with a valid key that is
   authorised in the taskcluster team password store. Set the gpg agent's cache
   so that you aren't prompted for your passphrase during the run, e.g. by
   writing the following to `~/.gnupg/gpg-agent.conf`:

   ```
   default-cache-ttl 86400
   max-cache-ttl 86400
   ```

7) macOS workers: a connection to the Mozilla corporate VPN, and a VNC session
   as administrator on each Mac, to avoid ssh connection problems. The script
   checks it can ssh to each Mac and run `sudo` before doing anything else.

## What it does

Before triggering the builds, any `taskcluster_version` in worker-images' `config/tceng/` that
isn't the latest Taskcluster release is bumped in a PR (with auto-merge enabled,
so it lands as soon as it is approved), and the script waits for it to merge
(`UPDATE_TASKCLUSTER_VERSION=false` skips this). The PR is opened as soon as the
logins and other setup steps have completed, so it can be reviewed while
instance types/VM sizes/machine types are updated and macOS workers are
deployed; only triggering the builds waits for it to be merged. Failed
worker-images jobs are rerun, up to `MAX_RUN_ATTEMPTS` attempts. Azure images
that worker-images built in another subscription are copied into ours by
`copy-azure-images.py` before `tc-admin apply` switches worker pools to them.
Finally, the new images are logged with links to the worker-images jobs that
built them, and a PR is opened (from your fork) to have
fxci's worker pools that use the same images use the new ones too
(`UPDATE_FXCI_IMAGES=false` skips this). It isn't opened if any location that
fxci uses has no new image, e.g. because its build failed.

## Environment variables

All default to `true`, apart from `MAX_RUN_ATTEMPTS`.

| Variable | Controls |
|---|---|
| `UPDATE_OFFERINGS` | Update EC2 instance types, Azure VM sizes and GCE machine types, and `tc-admin apply` |
| `DEPLOY_MACS` | Update the macOS workers |
| `BUILD_IMAGES` | Have worker-images build new images, and commit them to `config/imagesets.yml` |
| `UPDATE_TASKCLUSTER_VERSION` | Bump worker-images' TCEng configs to the latest Taskcluster release before building |
| `MAX_RUN_ATTEMPTS` | Attempts per worker-images workflow run, including reruns of failed jobs (default `3`) |
| `DEPLOY_IMAGES` | Copy Azure images into place and `tc-admin apply` |
| `UPDATE_FXCI_IMAGES` | Open the fxci-config PR to use the new images |
| `LOGIN_AWS` / `LOGIN_AZURE` | Sign in to AWS / Azure (`false` to use an existing session) |
| `UPDATE_GCLOUD` | Run `gcloud components update` |

After a run, test the new images, e.g. by rerunning some tasks that previously
ran successfully.

## Required tools

All of the following tools must be available in the `PATH`:

  * `aws`
  * `az`
  * `bash`
  * `curl`
  * `cut`
  * `dirname`
  * `env`
  * `gcloud`
  * `gh` (logged in with `gh auth login`)
  * `git`
  * `head`
  * `mktemp`
  * `pass`
  * `python3`
  * `rm`
  * `sleep`
  * `sort`
  * `ssh`
  * `tail`
  * `which`
