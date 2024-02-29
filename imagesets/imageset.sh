#!/usr/bin/env bash

set -eu
set -o pipefail

function log {
  if [ -n "${BACKGROUND_COLOUR-}" ] && [ -n "${FOREGROUND_COLOUR-}" ] && [ -n "${CLOUD-}" ] && [ -n "${IMAGE_SET-}" ] && [ -n "${REGION-}" ]; then
    echo -e "\x1B[48;5;${BACKGROUND_COLOUR}m\x1B[38;5;${FOREGROUND_COLOUR}m$(basename "${0}"): $(date): ${CLOUD}: ${IMAGE_SET}: ${REGION}: ${@}\x1B[K\x1B[0m"
  else
    echo -e "\x1B[48;5;123m\x1B[38;5;0m$(basename "${0}"): $(date): ${@}\x1B[K\x1B[0m"
  fi
}

function deploy {

  log "Checking system dependencies..."

  # Presumably bash and env must already be in the PATH to reach this point,
  # but let's keep them in the dependency list in case this list is
  # copy/pasted to any docs, etc. Having them here doesn't do any harm.
  for command in aws base64 basename bash cat chmod cut date dirname env find gcloud git head mktemp pass rm sed sleep sort tail touch which xargs yq; do
    if ! which "${command}" > /dev/null; then
      log "  \xE2\x9D\x8C ${command}"
      log "${0} requires ${command} to be installed and available in your PATH - please fix and rerun" >&2
      exit 64
    else
      log "  \xE2\x9C\x94 ${command}"
    fi
  done

  if [ -z "$(yq --version 2>&1 | sed -n 's/version 3\./x/p')" ]; then
    log "${0} requires yq version 3 in your PATH, but you have:" >&2
    log "    $(which yq)" >&2
    log "    $(yq --version 2>&1)" >&2
    log "See https://mikefarah.gitbook.io/yq/upgrading-from-v3 about backward incompatibility of version 4 and higher." >&2
    log "Note, an alternative solution is to upgrade this script to use v4 syntax and rebuild/publish docker container etc." >&2
    exit 65
  else
    log "  \xE2\x9C\x94 yq is version 3"
  fi

  log "Checking inputs..."

  if [ "${#}" -ne 3 ]; then
    log "Please specify a cloud (aws/google), action (delete|update), and image set (e.g. generic-worker-win2022) e.g. ${0} aws update generic-worker-win2022" >&2
    exit 66
  fi

  export CLOUD="${1}"
  if [ "${CLOUD}" != "aws" ] && [ "${CLOUD}" != "google" ]; then
    log "Provider must be 'aws' or 'google' but '${CLOUD}' was specified" >&2
    exit 67
  fi

  ACTION="${2}"
  if [ "${ACTION}" != "update" ] && [ "${ACTION}" != "delete" ]; then
    log "Action must be 'delete' or 'update' but '${ACTION}' was specified" >&2
    exit 68
  fi

  export IMAGE_SET="${3}"

  OFFICIAL_GIT_REPO='git@github.com:taskcluster/community-tc-config'

  # Local changes should be dealt with before continuing. git stash can help
  # here! Untracked files shouldn't get pushed, so let's make sure we have none.
  modified="$(git status --porcelain)"
  if [ -n "${modified}" ]; then
    log ""
    log "There are changes in the local tree. This probably means" >&2
    log "you'll do something unintentional. For safety's sake, please" >&2
    log 'revert or stash them!' >&2
    git status
    exit 69
  fi

  # Check that the current HEAD is also the tip of the official repo main
  # branch. If the commits match, it does not matter what the local branch
  # name is, or even if we have a detached head.
  remoteMasterSha="$(git ls-remote "${OFFICIAL_GIT_REPO}" main | cut -f1)"
  localSha="$(git rev-parse HEAD)"
  if [ "${remoteMasterSha}" != "${localSha}" ]; then
    log ""
    log "Locally, you are on commit ${localSha}." >&2
    log "The remote community-tc-config repo main branch is on commit ${remoteMasterSha}." >&2
    log "Make sure to git push/pull so that they both point to the same commit." >&2
    exit 70
  fi

  if [ "${CLOUD}" == "google" ] && [ -z "${GCP_PROJECT-}" ]; then
    log "Environment variable GCP_PROJECT must be exported before calling this script" >&2
    exit 71
  fi

  if ! [ -d "${IMAGE_SET}" ]; then
    log "Directory $(pwd)/${IMAGE_SET} not found - please specify a valid directory for image set" >&2
    exit 72
  fi

  export IMAGE_SET_COMMIT_SHA="$(git rev-parse HEAD)"

  # generate 20 char random identifier from chars [a-z0-9]
  export UUID="$(cat /dev/urandom | head -c 256 | base64 | sed 's/[^a-z0-9]//g' | head -c 20)"
  export UNIQUE_NAME="${IMAGE_SET}-${UUID}"

  export TEMP_DIR="$(mktemp -d -t password-store.XXXXXXXXXX)"
  export PASSWORD_STORE_DIR="${TEMP_DIR}/.password-store"
  # Register your ssh public key with https://source.cloud.google.com/user/ssh_keys?register=true
  #
  # Add the following to your ~/.ssh/config:
  #
  # Host source.developers.google.com
  #  User <user>@mozilla.com
  #  UpdateHostKeys yes
  #  IdentityFile <path to your private key>
  #  Port 2022
  #
  git clone ssh://source.developers.google.com/p/taskcluster-passwords/r/secrets "${PASSWORD_STORE_DIR}"
  git -C "${PASSWORD_STORE_DIR}" config pass.signcommits false
  git -C "${PASSWORD_STORE_DIR}" config commit.gpgsign false

  head_sha_password_store="$(pass git rev-parse HEAD)"
  echo test | pass insert -m -f "test"
  if [ "$(pass test)" != "test" ]; then
    log "Problem writing to password store" >&2
    exit 73
  fi
  # Note, we could have used `HEAD~1` rather than the explicit commit id here,
  # however if the `pass insert` command above didn't result in a git commit
  # (e.g. because test.gpg is in a gitignore list of the user or repo) then we
  # would end up removing the wrong commit. Using the explicit commit id here
  # protects against those type of edge cases.
  pass git reset --hard "${head_sha_password_store}" > /dev/null 2>&1

  log 'Starting!'

  case "${CLOUD}" in
    aws)
      if [ -z "${AWS_ACCESS_KEY_ID-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY-}" ] || [ -z "${AWS_SESSION_TOKEN-}" ]; then
        log "Need AWS credentials..."
        eval "$(./signin-aws.sh)"
      fi
      echo us-west-1 118 246 us-west-2 199 220 us-east-1 4 200 us-east-2 33 210 | xargs -P4 -n3 "./$(basename "${0}")" process-region "${CLOUD}_${ACTION}"
      log "Fetching secrets..."
      pass git pull
      for REGION in us-west-1 us-west-2 us-east-1 us-east-2; do
        # some regions may not have secrets if they do not support the required instance type
        if [ -f "${IMAGE_SET}/aws.${REGION}.secrets" ]; then
          IMAGE_ID="$(cat "${IMAGE_SET}/aws.${REGION}.secrets" | sed -n 's/^AMI: *//p')"
          yq w -i ../config/imagesets.yml "${IMAGE_SET}.aws.amis.${REGION}" "${IMAGE_ID}"
          pass insert -m -f "community-tc/imagesets/${IMAGE_SET}/${REGION}" < "${IMAGE_SET}/aws.${REGION}.secrets"
          pass insert -m -f "community-tc/imagesets/${IMAGE_SET}/${CLOUD}.${REGION}.id_rsa" < "${IMAGE_SET}/${CLOUD}.${REGION}.id_rsa"
        fi
      done
      log "Pushing new secrets..."
      pass git push
      ;;
    google)
      echo us-central1-a 21 230 | xargs -P1 -n3 "./$(basename "${0}")" process-region "${CLOUD}_${ACTION}"
      log "Updating config/imagesets.yml..."
      IMAGE_NAME="$(cat "${IMAGE_SET}/gcp.secrets")"
      yq w -i ../config/imagesets.yml "${IMAGE_SET}.gcp.image" "${IMAGE_NAME}"
      ;;
  esac

  rm -rf "${TEMP_DIR}"

  # Link to bootstrap script in worker type metadata, if generic-worker worker type
  if [ "$(yq r ../config/imagesets.yml "${IMAGE_SET}.workerImplementation")" == "generic-worker" ]; then
    BOOTSTRAP_SCRIPT="$(echo "${IMAGE_SET}"/bootstrap.*)"
    yq w -i ../config/imagesets.yml "${IMAGE_SET}.workerConfig.genericWorker.config.workerTypeMetadata.machine-setup.script" "https://github.com/taskcluster/community-tc-config/blob/${IMAGE_SET_COMMIT_SHA}/imagesets/${BOOTSTRAP_SCRIPT}"
  fi

  git add ../config/imagesets.yml

  case "${CLOUD}" in
    aws)
      git commit -m "Built new AWS AMIs for imageset ${IMAGE_SET}"
      ;;
    google)
      git commit -m "Built new google machine image for imageset ${IMAGE_SET}"
      ;;
  esac

  git -c pull.rebase=true pull "${OFFICIAL_GIT_REPO}" main
  git push "${OFFICIAL_GIT_REPO}" "+HEAD:refs/heads/main"
  log 'Deployment of image sets successful!'
  log ''
  log 'Be sure to run tc-admin in the community-tc-config repo to apply changes to the community cluster!'
}

################## AWS ##################

function aws_delete {
  aws_find_old_objects
  aws_delete_found
}

function aws_find_old_objects {
  # query old instances
  log "Querying old instances..."
  OLD_INSTANCES="$(aws --region "${REGION}" ec2 describe-instances --filters "Name=tag:ImageSet,Values=${IMAGE_SET}" --query 'Reservations[*].Instances[*].InstanceId' --output text)"

  # find old amis
  log "Querying previous AMI..."
  OLD_SNAPSHOTS="$(aws --region "${REGION}" ec2 describe-images --owners self --filters "Name=name,Values=${IMAGE_SET} *" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' --output text)"

  # find old snapshots
  log "Querying snapshot used in this previous AMI..."
  OLD_AMIS="$(aws --region "${REGION}" ec2 describe-images --owners self --filters "Name=name,Values=${IMAGE_SET} *" --query 'Images[*].ImageId' --output text)"
}

function aws_delete_found {
  # terminate old instances
  if [ -n "${OLD_INSTANCES}" ]; then
    log "Now terminating instances" ${OLD_INSTANCES}...
    for instance in ${OLD_INSTANCES}; do
      aws --region "${REGION}" ec2 terminate-instances --instance-ids "${instance}" > /dev/null 2>&1 || log "WARNING: Could not terminate instance ${instance}"
    done
  else
    log "No previous instances to terminate."
  fi

  # deregister old AMIs
  if [ -n "${OLD_AMIS}" ]; then
    log "Deregistering the old AMI(s) ("${OLD_AMIS}")..."
    # note this can fail if it is already in process of being deregistered, so allow to fail...
    for image in ${OLD_AMIS}; do
      aws --region "${REGION}" ec2 deregister-image --image-id "${image}" > /dev/null 2>&1 || log "WARNING: Could not deregister image ${image}"
    done
  else
    log "No old AMI to deregister."
  fi

  # delete old snapshots
  if [ -n "${OLD_SNAPSHOTS}" ]; then
    log "Deleting the old snapshot(s) ("${OLD_SNAPSHOTS}")..."
    for snapshot in ${OLD_SNAPSHOTS}; do
      aws --region "${REGION}" ec2 delete-snapshot --snapshot-id ${snapshot} > /dev/null 2>&1 || log "WARNING: Could not delete snapshot ${snapshot}"
    done
  else
    log "No old snapshot to delete."
  fi
}

function aws_update {

  log "Generating new ssh key..."
  rm -rf "${CLOUD}.${REGION}.id_rsa"
  aws --region "${REGION}" ec2 delete-key-pair --key-name "${IMAGE_SET}_${REGION}" || true
  aws --region "${REGION}" ec2 create-key-pair --key-name "${IMAGE_SET}_${REGION}" --query 'KeyMaterial' --output text > "${CLOUD}.${REGION}.id_rsa"
  chmod 400 "${CLOUD}.${REGION}.id_rsa"

  # search for latest base AMI to use
  AMI_METADATA="$(aws --region "${REGION}" ec2 describe-images --owners $(cat aws_owners) --filters $(cat aws_filters) --query 'Images[*].{A:CreationDate,B:ImageId,C:Name}' --output text | sort -u | tail -1 | cut -f2,3)"

  AMI="$(echo $AMI_METADATA | sed 's/ .*//')"
  AMI_NAME="$(echo $AMI_METADATA | sed 's/.* //')"
  log "Base AMI is: ${AMI} ('${AMI_NAME}')"

  aws_find_old_objects

  TEMP_SETUP_SCRIPT="$(mktemp -t ${UNIQUE_NAME}.XXXXXXXXXX)"

  if [ -f "bootstrap.ps1" ]; then
    echo '<powershell>' >> "${TEMP_SETUP_SCRIPT}"
    cat bootstrap.ps1 | sed 's/%MY_CLOUD%/aws/g' >> "${TEMP_SETUP_SCRIPT}"
    echo '</powershell>' >> "${TEMP_SETUP_SCRIPT}"
    IMAGE_OS=windows
  else
    cat bootstrap.sh | sed 's/%MY_CLOUD%/aws/g' >> "${TEMP_SETUP_SCRIPT}"
    IMAGE_OS=linux
  fi

  # Make sure we have an ssh security group in this region note if we *try* to
  # create a security group that already exists (regardless of whether it is
  # successful or not), there will be a cloudwatch alarm, so avoid this by
  # checking first.
  echo 'ssh-only 22 SSH only
    rdp-only 3389 RDP only' | while read group_name port description; do
    if ! aws --region "${REGION}" ec2 describe-security-groups --group-names "${group_name}" > /dev/null 2>&1; then
      SECURITY_GROUP="$(aws --region "${REGION}" ec2 create-security-group --group-name "${group_name}" --description "${description}" --output text 2> /dev/null || true)"
      aws --region "${REGION}" ec2 authorize-security-group-ingress --group-id "${SECURITY_GROUP}" --ip-permissions '[{"IpProtocol": "tcp", "FromPort": '"${port}"', "ToPort": '"${port}"', "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]'
    fi
  done

  # Create a new role with access granted by the aws_access_policy.
  if [ -f "aws_instance_profile" ]; then
    PROFILE="Name=$(cat aws_instance_profile)"
  fi

  # Create new base AMI, and apply user-data filter output, to get instance ID.
  if ! INSTANCE_ID="$(aws --region "${REGION}" ec2 run-instances --image-id "${AMI}" --key-name "${IMAGE_SET}_${REGION}" --security-groups "rdp-only" "ssh-only" --user-data "$(cat "${TEMP_SETUP_SCRIPT}")" --instance-type $(cat aws_base_instance_type) --block-device-mappings DeviceName=/dev/sda1,Ebs='{VolumeSize=75,DeleteOnTermination=true,VolumeType=gp2}' --instance-initiated-shutdown-behavior stop --client-token "${UNIQUE_NAME}" --query 'Instances[*].InstanceId' --output text ${PROFILE:+--iam-instance-profile $PROFILE} 2>&1)"; then
    log "Cannot deploy in ${REGION} since instance type $(cat aws_base_instance_type) is not supported; skipping."
    return 0
  fi

  log "I've triggered the creation of instance ${INSTANCE_ID} - it can take a \x1B[4mVery Long Time™\x1B[24m for it to be created and bootstrapped..."
  aws --region "${REGION}" ec2 create-tags --resources "${INSTANCE_ID}" --tags "Key=ImageSet,Value=${IMAGE_SET}" "Key=Name,Value=${IMAGE_SET} base instance ${IMAGE_SET_COMMIT_SHA}" "Key=TC-Windows-Base,Value=true"
  log "I've tagged it with \"ImageSet\": \"${IMAGE_SET}\""

  sleep 1

  # grab public IP before it shuts down and loses it!
  PUBLIC_IP="$(aws --region "${REGION}" ec2 describe-instances --instance-id "${INSTANCE_ID}" --query 'Reservations[*].Instances[*].NetworkInterfaces[*].Association.PublicIp' --output text)"

  if [ "${IMAGE_OS}" == "windows" ]; then
    until [ -n "${PASSWORD-}" ]; do
      log "    Waiting for Windows Password from ${INSTANCE_ID} (IP ${PUBLIC_IP})..."
      sleep 10
      PASSWORD="$(aws --region "${REGION}" ec2 get-password-data --instance-id "${INSTANCE_ID}" --priv-launch-key ${CLOUD}.${REGION}.id_rsa --output text --query PasswordData 2> /dev/null || true)"
    done
  fi

  log "To connect to the template instance (please don't do so until AMI creation process is completed"'!'"):"
  log ''

  if [ "${IMAGE_OS}" == "windows" ]; then
    log "                         Public IP:   ${PUBLIC_IP}"
    log "                         Username:    Administrator"
    log "                         Password:    ${PASSWORD}"
  else
    # linux
    log "                         ssh -i '$(pwd)/${CLOUD}.${REGION}.id_rsa' ubuntu@${PUBLIC_IP}"
  fi

  # poll for a stopped state
  until aws --region "${REGION}" ec2 wait instance-stopped --instance-ids "${INSTANCE_ID}" > /dev/null 2>&1; do
    log "    Waiting for instance ${INSTANCE_ID} (IP ${PUBLIC_IP}) to shut down..."
    sleep 30
  done

  rm "${TEMP_SETUP_SCRIPT}"

  log "Now snapshotting the instance to create an AMI..."
  # now capture the AMI
  IMAGE_ID="$(aws --region "${REGION}" ec2 create-image --instance-id "${INSTANCE_ID}" --name "${IMAGE_SET} version ${IMAGE_SET_COMMIT_SHA} (${UUID})" --description "${IMAGE_SET} version ${IMAGE_SET_COMMIT_SHA} (${UUID})" --output text)"

  log "The AMI is currently being created: ${IMAGE_ID}"

  log ''
  log "To monitor the AMI creation process, see:"
  log ''
  log "                         https://${REGION}.console.aws.amazon.com/ec2/v2/home?region=${REGION}#Images:visibility=owned-by-me;search=${IMAGE_ID};sort=desc:platform"

  log "I've triggered the snapshot of instance ${INSTANCE_ID} as ${IMAGE_ID} - but now we will need to wait a \x1B[4mVery Long Time™\x1B[24m for it to be created..."

  until aws --region "${REGION}" ec2 wait image-available --image-ids "${IMAGE_ID}" > /dev/null 2>&1; do
    log "    Waiting for ${IMAGE_ID} availability..."
    sleep 30
  done

  {
    echo "Instance:    ${INSTANCE_ID}"
    echo "Public IP:   ${PUBLIC_IP}"
    if [ -n "${PASSWORD-}" ]; then
      echo "Username:    Administrator"
      echo "Password:    ${PASSWORD}"
    fi
    echo "AMI:         ${IMAGE_ID}"
  } > "aws.${REGION}.secrets"

  aws_delete_found
}

################## GOOGLE ##################

function google_delete {
  google_find_old_objects
  google_delete_found
}

function google_find_old_objects {
  log "Querying old instances..."
  OLD_INSTANCES="$(gcloud compute instances list --project="${GCP_PROJECT}" --filter="labels.image-set=${IMAGE_SET} AND zone:${REGION}" --format='table[no-heading](name)')"
  if [ -n "${OLD_INSTANCES}" ]; then
    log "Found old instances:" $OLD_INSTANCES
  else
    log "WARNING: No old instances found"
  fi

  log "Querying previous images..."
  OLD_IMAGES="$(gcloud compute images list --project="${GCP_PROJECT}" --filter="labels.image-set=${IMAGE_SET}" --format='table[no-heading](name)')"
  if [ -n "${OLD_IMAGES}" ]; then
    log "Found old images:" $OLD_IMAGES
  else
    log "WARNING: No old images found"
  fi
}

function google_delete_found {
  # terminate old instances
  if [ -n "${OLD_INSTANCES}" ]; then
    log "Now terminating instances" ${OLD_INSTANCES}...
    gcloud compute instances delete ${OLD_INSTANCES} --zone="${REGION}" --delete-disks=all --project="${GCP_PROJECT}" --quiet
  else
    log "No previous instances to terminate."
  fi

  # delete old images
  if [ -n "${OLD_IMAGES}" ]; then
    log "Deleting the old image(s) ("${OLD_IMAGES}")..."
    gcloud compute images delete ${OLD_IMAGES} --project="${GCP_PROJECT}" --quiet
  else
    log "No old snapshot to delete."
  fi
}

function google_update {

  # NOTE: to grant permission for community-tc worker manager to use images in your GCP project, run:
  # gcloud projects add-iam-policy-binding "${GCP_PROJECT}" --member serviceAccount:taskcluster-worker-manager@taskcluster-temp-workers.iam.gserviceaccount.com --role roles/compute.imageUser

  # Prefer no ssh keys, see: https://cloud.google.com/compute/docs/instances/adding-removing-ssh-keys

  google_find_old_objects

  TEMP_SETUP_SCRIPT="$(mktemp -t ${UNIQUE_NAME}.XXXXXXXXXX)"

  if [ -f "bootstrap.ps1" ]; then
    PLATFORM=windows
    echo '&{' >> "${TEMP_SETUP_SCRIPT}"
    cat bootstrap.ps1 | sed 's/%MY_CLOUD%/google/g' >> "${TEMP_SETUP_SCRIPT}"
    echo '} 5>&1 4>&1 3>&1 2>&1 > C:\update_google.log' >> "${TEMP_SETUP_SCRIPT}"
    STARTUP_KEY=windows-startup-script-ps1
  else
    PLATFORM=linux
    cat bootstrap.sh | sed 's/%MY_CLOUD%/google/g' >> "${TEMP_SETUP_SCRIPT}"
    STARTUP_KEY=startup-script
  fi

  gcloud compute --project="${GCP_PROJECT}" instances create "${UNIQUE_NAME}" --description="instance for image set ${IMAGE_SET}" --zone="${REGION}" --machine-type="$(cat gcp_base_instance_type)" --subnet=default --network-tier=PREMIUM --metadata-from-file="${STARTUP_KEY}=${TEMP_SETUP_SCRIPT}" --no-restart-on-failure --maintenance-policy=MIGRATE --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append $(cat gcp_filters) --boot-disk-device-name="${UNIQUE_NAME}" --labels="image-set=${IMAGE_SET}" --reservation-affinity=any

  log "I've triggered the creation of instance ${UNIQUE_NAME} - it can take a \x1B[4mVery Long Time™\x1B[24m for it to be created and bootstrapped..."

  log "To connect to the template instance:"
  log ''
  log "                         gcloud compute ssh ${UNIQUE_NAME} --project='${GCP_PROJECT}' --zone=${REGION}"
  log ''

  if [ "${PLATFORM}" == "windows" ]; then
    until gcloud compute reset-windows-password "${UNIQUE_NAME}" --zone="${REGION}" --project="${GCP_PROJECT}"; do
      sleep 15
    done
  fi

  # poll for a stopped state

  until [ "$(gcloud compute --project="${GCP_PROJECT}" instances describe --zone="${REGION}" "${UNIQUE_NAME}" --format='table[no-heading](status)')" == 'TERMINATED' ]; do
    log "    Waiting for instance ${UNIQUE_NAME} to shut down..."
    sleep 15
  done

  rm "${TEMP_SETUP_SCRIPT}"

  log "Now creating an image from the terminated instance..."
  # gcloud compute disks snapshot "${UNIQUE_NAME}" --project="${GCP_PROJECT}" --description="my description" --labels="key1=value1" --snapshot-names="${UNIQUE_NAME}" --zone="${REGION}" --storage-location=us
  gcloud compute images create "${UNIQUE_NAME}" --source-disk="${UNIQUE_NAME}" --source-disk-zone="${REGION}" --labels="image-set=${IMAGE_SET}" --project="${GCP_PROJECT}"

  log ''
  log "The image is being created here:"
  log ''
  log "                         https://console.cloud.google.com/compute/imagesDetail/projects/${GCP_PROJECT}/global/images/${UNIQUE_NAME}?project=${GCP_PROJECT}&authuser=1&supportedpurview=project"

  until [ "$(gcloud compute --project="${GCP_PROJECT}" images describe "${UNIQUE_NAME}" --format='table[no-heading](status)')" == 'READY' ]; do
    log "    Waiting for image ${UNIQUE_NAME} to be created..."
    sleep 15
  done

  echo "projects/${GCP_PROJECT}/global/images/${UNIQUE_NAME}" > gcp.secrets

  google_delete_found
}

################## Entry point ##################

if [ "${1-}" == "process-region" ]; then
  # Step into directory containing image set definition.
  cd "$(dirname "${0}")/${IMAGE_SET}"
  REGION="${3}"
  FOREGROUND_COLOUR="${4}"
  BACKGROUND_COLOUR="${5}"
  "${2}"
  exit 0
fi

cd "$(dirname "${0}")"
deploy "${@}"
