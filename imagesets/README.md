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

1) Docker, e.g. [Colima](https://github.com/abiosoft/colima) (`brew install
   colima docker && colima start`) or Docker Desktop on macOS, or Docker Engine
   on Linux, and `git`. Nothing else needs installing: the script runs in a
   container with the tools it needs ([`container/Dockerfile`](container/Dockerfile)),
   which it builds, and rebuilds each week to update them (which takes a few
   minutes).

2) AWS: the `AdministratorAccess` role on account `moz-fx-tc-community-workers`
   (885316786408) in [Mozilla's AWS SSO](https://mozilla-cloudservices.awsapps.com/start).

3) GitHub: an account that can push to this repository.

4) git: `user.name` and `user.email` set.

5) gpg: a key that the taskcluster team password store is encrypted to, and
   which can sign: `user.signingkey`, or else the key of `user.email`, in your
   gpg home (`$GNUPGHOME`, or `~/.gnupg`). Only the key is used, by the
   container's gpg (rather than your gpg, agent or configuration): its
   passphrase is asked for once, at the start, and kept only in memory, giving
   it to the commands that need it. Every commit the script makes is signed
   with it, whatever your git settings, and checked before pushing; add it to
   your GitHub account, for GitHub to show them as verified. Keys on a
   smartcard aren't supported.

6) macOS workers (`prod` and `all`): a Mozilla LDAP account (your git email,
   if it is a mozilla.com one, or set `IMAGESET_LDAP_USERNAME`) with an
   authenticator app for 2FA (Duo's "Hardware token" option), and a VNC session
   as administrator on each Mac. The Macs are only reachable through the
   Mozilla VPN, which the container connects to (only the container uses it,
   so Viscosity isn't needed). The first time, the script downloads your VPN
   certificate from [login.mozilla.com](https://login.mozilla.com/openvpn/)
   (with your LDAP password and a 2FA code), and keeps it encrypted to your gpg
   key; connecting needs another 2FA code, each time. The Macs are updated
   right after the sign-ins, so that the VPN is only needed while you are
   there. If a Mac is reinstalled, update [`mac_known_hosts`](mac_known_hosts).

Signing in to Google Cloud, GitHub, Azure and AWS happens in your browser:
the script opens each page, with any one-time code in your clipboard. Without
a browser (e.g. over ssh), it shows the URL and code instead.

The script doesn't use your own configuration of any tools, nor your checkout
of this repository: it clones upstream `main`, and the container signs in
during the run, and clones the password store. To test local changes to the
scripts, set `IMAGESET_LOCAL_CHANGES=true`. If it isn't set, and your
checkout's files differ from upstream `main`'s, the script lists them, and
asks whether to use them. It keeps progress (for resuming) and the encrypted
VPN certificate in `~/.cache/community-tc-imagesets`.

## What it does

Before triggering the builds, any `taskcluster_version` in worker-images' `config/tceng/` that
isn't the latest Taskcluster release is bumped in a PR (with auto-merge enabled,
so it lands as soon as it is approved), and the script waits for it to merge
(`UPDATE_TASKCLUSTER_VERSION=false` skips this). The PR is opened as soon as the
logins and other setup steps have completed, so it can be reviewed while
macOS workers are deployed and instance types/VM sizes/machine types are
updated; only triggering the builds waits for it to be merged. Failed
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
| `IMAGESET_RESUME` | Whether to resume an unfinished run of the same target (skipping the steps it completed, and waiting for its worker-images builds rather than triggering new ones), rather than start again | asks |
| `IMAGESET_LDAP_USERNAME` | Your Mozilla LDAP username, for the VPN | your git email, if a mozilla.com one |

If a run fails, it says which step failed. Rerun the same command to continue
from there: it asks whether to resume, or to start again.

After a run, test the new images, e.g. by rerunning some tasks that previously
ran successfully.
