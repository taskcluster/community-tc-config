# Building Image Sets

## Prerequisite Steps

In order to build a set of gcp/aws machine images, you will require several
privileges. The following configuration will be required:

1) You will need an AWS access key configured under `~/.aws` on your host, and
   2FA should be enabled on your AWS account.

2) You will need a valid git configuration under `~/.gitconfig` on your host with
   a valid user/email, for committing changes to community-tc-config repo and the
   taskcluster team password store.

3) You will require the ssh private key for your git account to be available
   under `~/.ssh`.

4) You will either need to be connected to the Mozilla VPN in order to access
   git-internal.mozilla.org or you will need to have a proxy configured in your
   `~/.ssh/config` file, such as:

  ```
  Host git-internal.mozilla.org
      User gitolite3
      ProxyCommand ssh -W %h:%p -oProxyCommand=none ssh.mozilla.com
  ```

5) You will need your gpg account to be configured under `~/.gnupg` on your host,
   with a valid key that is authorised in the taskcluster team password store.

6) Depending on which cloud you are deploying to, there may be other steps
   required:

     * AWS only:

       * If you use a Yubikey:

         The image set building process requires that you are authenticated against
         AWS. If the env vars `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
         `AWS_SESSION_TOKEN` are not set, the
         [`signin-aws`](https://gist.githubusercontent.com/djmitche/80353576a0f389bf130bcb439f63d070/raw/75d161a3a1cac41247f0f2f19846b6f39b7a314a/signin-aws)
         script will be automatically run. However, the yubikey interface isn't
         supported when running under docker, so if you use a yubikey, it is recommended
         to download this script on your host and run `eval $(signin-aws)` before
         calling the `imageset-under-docker.sh` script.

       * Other MFA Device:
 
         No additional steps needed, you will be prompted for MFA codes as necessary.

     * GCP only:

       First run `export GCP_PROJECT=<your google cloud project of choice to deploy image into>` (typically `community-tc-workers`)

Once all of the above prerequisite steps have been made, you are in a position
to be able to build image sets.

## Building

### Under Docker (recommended)

To update/delete the image set `IMAGE_SET` whose definition is in the
subdirectory `<IMAGE_SET>`:

  * `./imageset-under-docker.sh (aws|google) (delete|update) IMAGE_SET`

This will launch a docker container to build the image set.

### Outside of Docker (not recommended)

If you instead prefer to build an image set natively on your host (not using docker):

  * `./imageset.sh (aws|google) (delete|update) IMAGE_SET`

All of the following tools must be available in the `PATH`:

  * `aws`
  * `basename`
  * `bash`
  * `cat`
  * `chmod`
  * `cut`
  * `date`
  * `dirname`
  * `env`
  * `find`
  * `gcloud`
  * `git`
  * `grep`
  * `head`
  * `mktemp`
  * `pass`
  * `rm`
  * `sed`
  * [`signin-aws`](https://gist.githubusercontent.com/djmitche/80353576a0f389bf130bcb439f63d070/raw/75d161a3a1cac41247f0f2f19846b6f39b7a314a/signin-aws)
  * `sleep`
  * `sort`
  * `tail`
  * `touch`
  * `tr`
  * `which`
  * `xargs`
  * `yq`

## Post image set building steps

There are some important, currently manual, post-image-set-building steps to
complete:

1) A new commit will have been made to your `community-tc-config` repository,
   updating image references in `/config/imagesets.yml`. Make sure to push this
   commit upstream (i.e. to `git@github.com:mozilla/community-tc-config.git`).

2) Apply the config changes by running `tc-admin`. Note, here is a script that
   does this, if you have not already set something up:


   ```bash
   #!/bin/bash -e
   rm -rf tc-admin
   mkdir tc-admin
   pip3 install --upgrade pip
   cd tc-admin
   python3 -m venv tc-admin-venv
   source tc-admin-venv/bin/activate
   pip3 install pytest
   pip3 install --upgrade pip
   git clone https://github.com/mozilla/community-tc-config
   cd community-tc-config
   pip3 install -e .
   which tc-admin
   pass git pull
   TASKCLUSTER_ROOT_URL=https://community-tc.services.mozilla.com tc-admin diff || true
   echo
   echo 'Applying in 60 seconds (Ctrl-C to abort)....'
   echo
   sleep 60
   echo 'Applying!'
   echo
   TASKCLUSTER_ROOT_URL=https://community-tc.services.mozilla.com tc-admin apply
   cd ../..
   rm -rf tc-admin
   ```

3) Don't forget to test your image set changes! Try rerunning some tasks that
   previously ran successfully.
