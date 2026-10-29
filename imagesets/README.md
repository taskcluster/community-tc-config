# Deploying Image Sets

Machine images are not built in this repository: they are built by the TCEng
GitHub Actions workflows of relops'
[worker-images](https://github.com/mozilla-platform-ops/worker-images)
repository. To have worker-images build new images, and deploy them to
community-tc's worker pools, run, from this directory, one of:

  * `./imageset.sh prod`: the production image sets (e.g.
    `generic-worker-ubuntu-24-04`), which pin a Taskcluster release
  * `./imageset.sh staging`: the staging image sets (e.g.
    `generic-worker-ubuntu-24-04-staging`), which are built from Taskcluster's
    `main` branch
  * `./imageset.sh all`: both

The image sets of each target are listed in `TARGET_WORKFLOWS` in
[`rel-sre-imagesets.py`](rel-sre-imagesets.py). The script always deploys to
AWS, Azure and GCP. `prod` and `all` also update the macOS workers. The
environment variables [below](#environment-variables) can skip some of the
steps.

## Prerequisites

1) AWS: the `AdministratorAccess` role on account `moz-fx-tc-community-workers`
   (885316786408) in [Mozilla's AWS SSO](https://mozilla-cloudservices.awsapps.com/start).

2) Azure and GCP: `az` and `gcloud` installed.

3) GitHub: `gh` installed, and an account that can push to this repository.

4) git: `user.name` and `user.email` set.

5) gpg: a key that the taskcluster team password store is encrypted to.

6) macOS workers (`prod` and `all`): **you must be connected to the Mozilla
   corporate VPN**, as the Macs are only reachable through it, and have a VNC
   session as administrator on each Mac. If a Mac is reinstalled, update
   [`mac_known_hosts`](mac_known_hosts).

The script doesn't use your own configuration of these tools (e.g.
`~/.ssh/config`, `~/.gitconfig`, `~/.aws/config`, `~/.azure`,
`~/.config/gcloud`, `~/.password-store`), apart from the AWS SSO token cache
(`~/.aws/sso/cache`), nor your checkout of this repository: it signs in during
the run, and clones upstream `main` and the password store into a temporary
directory. To test local changes to the scripts, set
`IMAGESET_LOCAL_CHANGES=true`.

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
The `workerTypeMetadata.machine-setup.script` of each image set with new images
is set to the URL of the bootstrap script in worker-images, at the commit the
images were built from, so that users can see how their worker was set up.
Finally, the new images are logged with links to the worker-images jobs that
built them, and a PR is opened (from your fork) to have
fxci's worker pools that use the same images use the new ones too
(`UPDATE_FXCI_IMAGES=false` skips this). It isn't opened if any location that
fxci uses has no new image, e.g. because its build failed. The PR also sets the
`worker-type-metadata.machine-setup.script` of each updated fxci image to the
same bootstrap script URL, which fxci merges into the `workerTypeMetadata` of
its worker pools.

## Environment variables

| Variable | Controls | Default |
|---|---|---|
| `UPDATE_OFFERINGS` | Update EC2 instance types, Azure VM sizes and GCE machine types, and `tc-admin apply` | `true` (`false` for `staging`) |
| `DEPLOY_MACS` | Update the macOS workers | `true` (`false` for `staging`) |
| `BUILD_IMAGES` | Have worker-images build new images, and commit them to `config/imagesets.yml` | `true` |
| `UPDATE_TASKCLUSTER_VERSION` | Bump worker-images' TCEng configs to the latest Taskcluster release before building | `true` (`false` for `staging`) |
| `MAX_RUN_ATTEMPTS` | Attempts per worker-images workflow run, including reruns of failed jobs (and of jobs cancelled for exceeding their time limit, but not of jobs cancelled by hand) | `5` |
| `DEPLOY_IMAGES` | Copy Azure images into place and `tc-admin apply` | `true` |
| `UPDATE_FXCI_IMAGES` | Open the fxci-config PR to use the new images | `true` |
| `IMAGESET_LOCAL_CHANGES` | Use the files of your checkout (other than `config/`), rather than upstream `main`'s, to test changes to the scripts | `false` |
| `UPDATE_GCLOUD` | Run `gcloud components update` | `true` |

After a run, test the new images, e.g. by rerunning some tasks that previously
ran successfully.

## Required tools

The script runs on macOS and Linux. It checks for the tools it needs before
doing anything else, and says how to install any that are missing:
`aws` (version 2), `az`, `gcloud`, `gh`, `git`, `gpg`, `pass`,
`python3` (3.10 or later, with `venv`), `ssh` (OpenSSH 8.4 or later), `curl`, `tar`, and
standard utilities. Without a browser (e.g. over ssh), signing in uses a URL and
code instead.
