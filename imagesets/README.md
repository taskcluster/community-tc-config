# Building Image Sets

## Prerequisite Steps

The AWS/Azure/GCP image set building machinery requires the following configuration
to be present:

1) Depending on which cloud you will be deploying to:

     * AWS only:

       You will need an AWS access key configured under `~/.aws` on your host,
       and 2FA should be enabled on your AWS account.

     * Azure only:

       You will need an az installed on your host, and you will need to logon on
       your host (`az login`) in order that `~/.azure` folder holds your logon
       information.

2) You will need a valid git configuration under `~/.gitconfig` on your host with
   a valid user/email, for committing changes to community-tc-config repo and the
   taskcluster team password store.

3) In order to read/write to taskcluster team password store, you will need
   `gcloud` installed on your host, and you will need to logon (`gcloud auth login
   <user>@mozilla.com`) in order that `~/.config/gcloud` folder holds your logon
   information.

4) The ssh key for pushing to the taskcluster password store should be in a file
   somewhere underneath `~/.ssh` on your host. This directory is mounted in to the
   docker container. If it is not in a standard location (e.g. `~/.ssh/id_rsa`,
   `~/.ssh/id_ed25519`, ...) then the location should be explicitly specified with
   an `IdentityFile` directive in the `~/.ssh/config` file (see point 3 above).

5) You will need your gpg account to be configured under `~/.gnupg` on your host,
   with a valid key that is authorised in the taskcluster team password store.

6) Depending on which cloud you are deploying to, there may be other steps
   required:

     * AWS only:

       * If you use a Yubikey:

         The image set building process requires that you are authenticated against
         AWS. If the env vars `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
         `AWS_SESSION_TOKEN` are not set, the [`signin-aws.sh`](signin-aws.sh)
         script will be automatically run. However, the yubikey interface isn't
         supported when running under docker, so if you use a yubikey, it is recommended
         to run `eval $(signin-aws.sh)` before calling the `imageset-under-docker.sh` script.

       * Other MFA Device:
 
         No additional steps needed, you will be prompted for MFA codes as necessary.

     * Azure only:

       First, run `export AZURE_IMAGE_RESOURCE_GROUP=<your Azure resource group of choice to deploy image into>`
       (typically `rg-tc-eng-images`). Worker Manager spawns instances in resource group
       `rg-tc-eng-worker-manager-VMs` but typically the machine images are stored in resource group
       `rg-tc-eng-images`.

     * GCP only:

       First run `export GCP_PROJECT=<your google cloud project of choice to deploy image into>`
       (typically `taskcluster-imaging`). Worker Manager spawns instances in project
       `community-tc-workers` but typically the machine images are stored in project
       `taskcluster-imaging`.

7) You should set the gpg agent appropriately to enable building images without
   being prompted for your signing key passphrase. For example, by writing the
   following content to file `~/.gnupg/gpg-agent.conf`:

   ```
   default-cache-ttl 86400
   max-cache-ttl 86400
   ```

Once all of the above prerequisite steps have been made, you are in a position
to be able to build image sets.

## Building

### Building and deploying all image sets in one go in parallel

Run:

  * `./imageset.sh all`

### Build single image set under Docker

To update/delete the image set `IMAGE_SET` whose definition is in the
subdirectory `<IMAGE_SET>`:

  * `./imageset-under-docker.sh (aws|azure|google) (delete|update) IMAGE_SET`

This will launch a docker container to build the image set.

### Build single image set natively on host

If you instead prefer to build an image set natively on your host (not using docker):

  * `./imageset.sh (aws|azure|google) (delete|update) IMAGE_SET`

All of the following tools must be available in the `PATH`:

  * `aws`
  * `az`
  * `basename`
  * `bash`
  * `cat`
  * `chmod`
  * `cut`
  * `date`
  * `dirname`
  * `env`
  * `find`
  * `flock`
  * `gcloud`
  * `git`
  * `grep`
  * `head`
  * `mktemp`
  * `pass`
  * `rm`
  * `sed`
  * `sleep`
  * `sort`
  * `tail`
  * `touch`
  * `tr`
  * `which`
  * `xargs`
  * `yq` **version 3** (version 4 is [backwardly incompatible](https://mikefarah.gitbook.io/yq/upgrading-from-v3))

## Post image set building steps when building a single image set

Note, this is not required when running `./imageset.sh all`.

There are some important, currently manual, post-image-set-building steps to
complete:

1) A new commit will have been made to your `community-tc-config` repository,
   updating image references in `/config/imagesets.yml`. Make sure to push this
   commit upstream (i.e. to `git@github.com:taskcluster/community-tc-config.git`).

2) Apply the config changes by running `tc-admin`. Note, here is a script that
   does this, if you have not already set something up:

   ```bash
   #!/bin/bash

   set -eu
   set -o pipefail

   cd "$(dirname "${0}")"

   export TASKCLUSTER_CLIENT_ID='static/taskcluster/root'
   export TASKCLUSTER_ACCESS_TOKEN="$(pass ls community-tc/root | head -1)"
   export TASKCLUSTER_ROOT_URL='https://community-tc.services.mozilla.com'
   unset TASKCLUSTER_CERTIFICATE

   pass git pull

   rm -rf tc-admin
   mkdir tc-admin

   cd tc-admin
   python3.11 -m venv tc-admin-venv
   source tc-admin-venv/bin/activate
   pip3 install pytest
   pip3 install --upgrade pip

   git clone https://github.com/taskcluster/community-tc-config
   cd community-tc-config

   pip3 install -e .
   which tc-admin

   tc-admin diff || true
   echo
   echo 'Applying in 60 seconds (Ctrl-C to abort)....'
   echo
   sleep 60
   echo 'Applying!'
   echo
   tc-admin apply

   echo "All done!"
   ```

3) Don't forget to test your image set changes! Try rerunning some tasks that
   previously ran successfully.
