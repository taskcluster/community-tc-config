#!/usr/bin/env bash

set -eu
set -o pipefail

function retry {
  set +e
  local n=0
  # 2^10 seconds is plenty
  local max=10
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command $@ failed" >&2
        sleep_time=$((2 ** n))
        echo "Sleeping $sleep_time seconds..." >&2
        sleep $sleep_time
        echo "Attempt $n/$max:" >&2
      else
        echo "Failed after $n attempts." >&2
        return 67
      fi
    }
  done
  set -e
}

function log {
  if [ -n "${BACKGROUND_COLOUR-}" ] && [ -n "${FOREGROUND_COLOUR-}" ] && [ -n "${CLOUD-}" ] && [ -n "${IMAGE_SET-}" ] && [ -n "${REGION-}" ]; then
    echo -e "\x1B[48;5;${BACKGROUND_COLOUR}m\x1B[38;5;${FOREGROUND_COLOUR}m$(basename "${0}"): $(date -u +"%Y-%m-%dT%H:%M:%SZ"): ${CLOUD}: ${IMAGE_SET}: ${REGION}: ${@}\x1B[K\x1B[0m"
  else
    echo -e "\x1B[48;5;123m\x1B[38;5;0m$(basename "${0}"): $(date): ${@}\x1B[K\x1B[0m"
  fi
}

function log-iff-fails {
  export TEMP_FILE="$(mktemp -t log-iff-fails.XXXXXXXXXX)"
  "${@}" > "${TEMP_FILE}" 2>&1
  local return_code=$?
  if [ "${return_code}" != 0 ]; then
    cat "${TEMP_FILE}"
  fi
  rm "${TEMP_FILE}"
  return "${return_code}"
}

function deploy {

  log "Checking system dependencies..."

  # Presumably bash and env must already be in the PATH to reach this point,
  # but let's keep them in the dependency list in case this list is
  # copy/pasted to any docs, etc. Having them here doesn't do any harm.
  for command in aws az base64 basename bash cat chmod cut date dirname env find flock gcloud git head mktemp pass rm sed sleep sort tail touch tr which xargs yq; do
    if ! which "${command}" > /dev/null; then
      log "  \xE2\x9D\x8C ${command}"
      log "${0} requires ${command} to be installed and available in your PATH - please fix and rerun" >&2
      return 64
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
    return 65
  else
    log "  \xE2\x9C\x94 yq is version 3"
  fi

  log "Checking inputs..."

  if [ "${#}" -ne 3 ]; then
    log "Please specify a cloud (aws/azure/google), action (delete|update), and image set (e.g. generic-worker-win2022) e.g. ${0} aws update generic-worker-win2022" >&2
    return 66
  fi

  export CLOUD="${1}"
  if [ "${CLOUD}" != "aws" ] && [ "${CLOUD}" != "azure" ] && [ "${CLOUD}" != "google" ]; then
    log "Provider must be 'aws', 'azure', or 'google' but '${CLOUD}' was specified" >&2
    return 67
  fi

  ACTION="${2}"
  if [ "${ACTION}" != "update" ] && [ "${ACTION}" != "delete" ]; then
    log "Action must be 'delete' or 'update' but '${ACTION}' was specified" >&2
    return 68
  fi

  export IMAGE_SET="${3}"

  # Local changes should be dealt with before continuing. git stash can help
  # here! Untracked files shouldn't get pushed, so let's make sure we have none.
  modified="$(git status --porcelain)"
  if [ -n "${modified}" ]; then
    log ""
    log "There are changes in the local tree. This probably means" >&2
    log "you'll do something unintentional. For safety's sake, please" >&2
    log 'revert or stash them!' >&2
    git status
    return 69
  fi

  # Check that the current HEAD is also the tip of the official repo main
  # branch. If the commits match, it does not matter what the local branch
  # name is, or even if we have a detached head.
  remoteMasterSha="$(retry git ls-remote "${OFFICIAL_GIT_REPO}" main | cut -f1)"
  localSha="$(git rev-parse HEAD)"
  if [ "${remoteMasterSha}" != "${localSha}" ]; then
    log ""
    log "Locally, you are on commit ${localSha}." >&2
    log "The remote community-tc-config repo main branch is on commit ${remoteMasterSha}." >&2
    log "Make sure to git push/pull so that they both point to the same commit." >&2
    return 70
  fi

  if [ "${CLOUD}" == "google" ] && [ -z "${GCP_PROJECT-}" ]; then
    log "Environment variable GCP_PROJECT must be exported before calling this script" >&2
    return 71
  fi

  if [ "${CLOUD}" == "azure" ] && [ -z "${AZURE_IMAGE_RESOURCE_GROUP-}" ]; then
    log "Environment variable AZURE_IMAGE_RESOURCE_GROUP must be exported before calling this script" >&2
    log "This resource group will be used for storing your created image(s)." >&2
    return 74
  fi

  if ! [ -d "${IMAGE_SET}" ]; then
    log "Directory $(pwd)/${IMAGE_SET} not found - please specify a valid directory for image set" >&2
    return 72
  fi

  export IMAGE_SET_COMMIT_SHA="$(git rev-parse HEAD)"

  # generate 20 char random identifier from chars [a-z0-9]
  export UUID="$(head -c 256 /dev/urandom | base64 | sed 's/[^a-z0-9]//g' | head -c 20)"
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
  retry git clone ssh://source.developers.google.com/p/taskcluster-passwords/r/secrets "${PASSWORD_STORE_DIR}"
  git -C "${PASSWORD_STORE_DIR}" config pass.signcommits true
  git -C "${PASSWORD_STORE_DIR}" config commit.gpgsign true

  head_sha_password_store="$(pass git rev-parse HEAD)"
  echo test | pass insert -m -f "test"
  if [ "$(pass test)" != "test" ]; then
    log "Problem writing to password store" >&2
    return 73
  fi
  # Note, we could have used `HEAD~1` rather than the explicit commit id here,
  # however if the `pass insert` command above didn't result in a git commit
  # (e.g. because test.gpg is in a gitignore list of the user or repo) then we
  # would end up removing the wrong commit. Using the explicit commit id here
  # protects against those type of edge cases.
  log-iff-fails pass git reset --hard "${head_sha_password_store}"

  log 'Starting!'

  case "${CLOUD}" in
    aws)
      if [ -z "${AWS_ACCESS_KEY_ID-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY-}" ] || [ -z "${AWS_SESSION_TOKEN-}" ]; then
        log "Need AWS credentials..."
        eval "$(./signin-aws.sh)"
      fi
      if [[ "$IMAGE_SET" == *-staging ]]; then
        echo us-east-1 4 200 | xargs -P1 -n3 "./$(basename "${0}")" process-region "${CLOUD}_${ACTION}"
      else
        echo us-west-1 118 246 us-west-2 199 220 us-east-1 4 200 us-east-2 33 210 | xargs -P4 -n3 "./$(basename "${0}")" process-region "${CLOUD}_${ACTION}"
      fi
      log "Fetching secrets..."
      retry pass git pull
      for REGION in us-west-1 us-west-2 us-east-1 us-east-2; do
        # Delete any preexisting value, in case we don't have a new one, e.g.
        # because we have switched instance type and the new one is not available
        # in a given region.
        yq d -i ../config/imagesets.yml "${IMAGE_SET}.aws.amis.${REGION}" # returns with exit code 0 even if entry doesn't exist
        # some regions may not have secrets if they do not support the required instance type
        if [ -f "${IMAGE_SET}/aws.${REGION}.secrets" ]; then
          IMAGE_ID="$(cat "${IMAGE_SET}/aws.${REGION}.secrets" | sed -n 's/^AMI: *//p')"
          yq w -i ../config/imagesets.yml "${IMAGE_SET}.aws.amis.${REGION}" "${IMAGE_ID}"
          pass insert -m -f "community-tc/imagesets/${IMAGE_SET}/${REGION}" < "${IMAGE_SET}/aws.${REGION}.secrets"
          pass insert -m -f "community-tc/imagesets/${IMAGE_SET}/${CLOUD}.${REGION}.id_rsa" < "${IMAGE_SET}/${CLOUD}.${REGION}.id_rsa"
        fi
      done
      log "Pushing new secrets..."
      retry pass git push
      ;;
    azure)
      if ! retry az account show > /dev/null 2>&1; then
        log "Need azure credentials..."
        log-iff-fails retry az login
      fi
      if [[ "$IMAGE_SET" == *-staging ]]; then
        echo eastus 15 250 | xargs -P1 -n3 "./$(basename "${0}")" process-region "${CLOUD}_${ACTION}"
      else
        echo centralus 26 215 eastus 15 250 eastus2 33 200 northcentralus 100 175 southcentralus 99 150 westus 75 225 westus2 60 160 | xargs -P7 -n3 "./$(basename "${0}")" process-region "${CLOUD}_${ACTION}"
      fi
      log "Fetching secrets..."
      retry pass git pull
      for REGION in centralus eastus eastus2 northcentralus southcentralus westus westus2; do
        # Delete any preexisting value, in case we don't have a new one, e.g.
        # because we have switched instance type and the new one is not available
        # in a given region.
        yq d -i ../config/imagesets.yml "${IMAGE_SET}.azure.images.${REGION}" # returns with exit code 0 even if entry doesn't exist
        # some regions may not have secrets if they do not support the required instance type
        if [ -f "${IMAGE_SET}/azure.${REGION}.secrets" ]; then
          IMAGE_ID="$(cat "${IMAGE_SET}/azure.${REGION}.secrets" | sed -n 's/^Image: *//p')"
          yq w -i ../config/imagesets.yml "${IMAGE_SET}.azure.images.${REGION}" "${IMAGE_ID}"
          pass insert -m -f "community-tc/imagesets/${IMAGE_SET}/${REGION}" < "${IMAGE_SET}/azure.${REGION}.secrets"
        fi
      done
      log "Pushing new secrets..."
      retry pass git push
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
    yq w -i ../config/imagesets.yml "${IMAGE_SET}.workerConfig.genericWorker.config.workerTypeMetadata.machine-setup.script" "https://raw.githubusercontent.com/taskcluster/community-tc-config/${IMAGE_SET_COMMIT_SHA}/imagesets/${BOOTSTRAP_SCRIPT}"
  fi

  git add ../config/imagesets.yml

  case "${CLOUD}" in
    aws)
      git commit -m "Built new AWS AMIs for imageset ${IMAGE_SET}"
      ;;
    azure)
      git commit -m "Built new Azure machine images for imageset ${IMAGE_SET}"
      ;;
    google)
      git commit -m "Built new google machine image for imageset ${IMAGE_SET}"
      ;;
  esac

  retry git -c pull.rebase=true pull "${OFFICIAL_GIT_REPO}" main
  retry git push "${OFFICIAL_GIT_REPO}" "+HEAD:refs/heads/main"
  log "Deployment of image set ${IMAGE_SET} successful"
  log ''
  log 'Be sure to run tc-admin to apply changes to the community cluster!'
}

################## AWS ##################

function aws_delete {
  aws_find_old_objects
  aws_delete_found
}

function aws_find_old_objects {
  # query old instances
  log "Querying old instances..."
  OLD_INSTANCES="$(retry aws --region "${REGION}" ec2 describe-instances --filters "Name=tag:ImageSet,Values=${IMAGE_SET}" --query 'Reservations[*].Instances[*].InstanceId' --output text)"

  # find old snapshots
  log "Querying previous AMI..."
  OLD_SNAPSHOTS="$(retry aws --region "${REGION}" ec2 describe-images --owners self --filters "Name=name,Values=${IMAGE_SET} *" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' --output text)"

  # find old amis
  log "Querying snapshot used in this previous AMI..."
  OLD_AMIS="$(retry aws --region "${REGION}" ec2 describe-images --owners self --filters "Name=name,Values=${IMAGE_SET} *" --query 'Images[*].ImageId' --output text)"
}

function aws_delete_found {
  # terminate old instances
  if [ -n "${OLD_INSTANCES}" ]; then
    log "Now terminating instances" ${OLD_INSTANCES}...
    for instance in ${OLD_INSTANCES}; do
      retry aws --region "${REGION}" ec2 terminate-instances --instance-ids "${instance}" > /dev/null 2>&1 || log "WARNING: Could not terminate instance ${instance}"
    done
  else
    log "No previous instances to terminate."
  fi

  # deregister old AMIs
  if [ -n "${OLD_AMIS}" ]; then
    log "Deregistering the old AMI(s) ("${OLD_AMIS}")..."
    # note this can fail if it is already in process of being deregistered, so allow to fail...
    for image in ${OLD_AMIS}; do
      retry aws --region "${REGION}" ec2 deregister-image --image-id "${image}" > /dev/null 2>&1 || log "WARNING: Could not deregister image ${image}"
    done
  else
    log "No old AMI to deregister."
  fi

  # delete old snapshots
  if [ -n "${OLD_SNAPSHOTS}" ]; then
    log "Deleting the old snapshot(s) ("${OLD_SNAPSHOTS}")..."
    for snapshot in ${OLD_SNAPSHOTS}; do
      retry aws --region "${REGION}" ec2 delete-snapshot --snapshot-id ${snapshot} > /dev/null 2>&1 || log "WARNING: Could not delete snapshot ${snapshot}"
    done
  else
    log "No old snapshot to delete."
  fi
}

function aws_update {

  log "Generating new ssh key..."
  rm -rf "${CLOUD}.${REGION}.id_rsa"
  aws --region "${REGION}" ec2 delete-key-pair --key-name "${IMAGE_SET}_${REGION}" || true
  retry aws --region "${REGION}" ec2 create-key-pair --key-name "${IMAGE_SET}_${REGION}" --query 'KeyMaterial' --output text > "${CLOUD}.${REGION}.id_rsa"
  chmod 400 "${CLOUD}.${REGION}.id_rsa"

  # search for latest base AMI to use
  AMI_METADATA="$(retry aws --region "${REGION}" ec2 describe-images --owners $(cat aws_owners) --filters $(cat aws_filters) --query 'Images[*].{A:CreationDate,B:ImageId,C:Name}' --output text | sort -u | tail -1 | cut -f2,3)"

  AMI="$(echo $AMI_METADATA | sed 's/ .*//')"
  AMI_NAME="$(echo $AMI_METADATA | sed 's/.* //')"
  log "Base AMI is: ${AMI} ('${AMI_NAME}')"

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
      SECURITY_GROUP="$(retry aws --region "${REGION}" ec2 create-security-group --group-name "${group_name}" --description "${description}" --output text 2> /dev/null || true)"
      retry aws --region "${REGION}" ec2 authorize-security-group-ingress --group-id "${SECURITY_GROUP}" --ip-permissions '[{"IpProtocol": "tcp", "FromPort": '"${port}"', "ToPort": '"${port}"', "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]'
    fi
  done

  # Create a new role with access granted by the aws_access_policy.
  if [ -f "aws_instance_profile" ]; then
    PROFILE="Name=$(cat aws_instance_profile)"
  fi

  # Create new base AMI, and apply user-data filter output, to get instance ID.
  if ! INSTANCE_ID="$(aws --region "${REGION}" ec2 run-instances --image-id "${AMI}" --key-name "${IMAGE_SET}_${REGION}" --security-groups "rdp-only" "ssh-only" --user-data "file://${TEMP_SETUP_SCRIPT}" --instance-type $(cat aws_base_instance_type) --block-device-mappings DeviceName=/dev/sda1,Ebs='{VolumeSize=75,DeleteOnTermination=true,VolumeType=gp2}' --instance-initiated-shutdown-behavior stop --client-token "${UNIQUE_NAME}" --query 'Instances[*].InstanceId' --output text ${PROFILE:+--iam-instance-profile $PROFILE} 2>&1)"; then
    log "Cannot deploy in ${REGION} since instance type $(cat aws_base_instance_type) is not supported; skipping."
    log "Failure was: ${INSTANCE_ID}"
    return 0
  fi

  log "I've triggered the creation of instance ${INSTANCE_ID} - it can take a \x1B[4mVery Long Time™\x1B[24m for it to be created and bootstrapped..."
  retry aws --region "${REGION}" ec2 create-tags --resources "${INSTANCE_ID}" --tags "Key=ImageSet,Value=${IMAGE_SET}" "Key=Name,Value=${IMAGE_SET} base instance ${IMAGE_SET_COMMIT_SHA}" "Key=TC-Windows-Base,Value=true"
  log "I've tagged it with \"ImageSet\": \"${IMAGE_SET}\""

  sleep 1

  # grab public IP before it shuts down and loses it!
  PUBLIC_IP="$(retry aws --region "${REGION}" ec2 describe-instances --instance-id "${INSTANCE_ID}" --query 'Reservations[*].Instances[*].NetworkInterfaces[*].Association.PublicIp' --output text)"

  if [ "${IMAGE_OS}" == "windows" ]; then
    until [ -n "${PASSWORD-}" ]; do
      log "    Waiting for Windows Password from ${INSTANCE_ID} (IP ${PUBLIC_IP})..."
      sleep 10
      PASSWORD="$(retry aws --region "${REGION}" ec2 get-password-data --instance-id "${INSTANCE_ID}" --priv-launch-key ${CLOUD}.${REGION}.id_rsa --output text --query PasswordData 2> /dev/null || true)"
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
  IMAGE_ID="$(retry aws --region "${REGION}" ec2 create-image --instance-id "${INSTANCE_ID}" --name "${IMAGE_SET} version ${IMAGE_SET_COMMIT_SHA} (${UUID})" --description "${IMAGE_SET} version ${IMAGE_SET_COMMIT_SHA} (${UUID})" --output text)"

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
}

################## GOOGLE ##################

function google_delete {
  google_find_old_objects
  google_delete_found
}

function google_find_old_objects {
  log "Querying old instances..."
  OLD_INSTANCES="$(retry gcloud compute instances list --project="${GCP_PROJECT}" --filter="labels.image-set=${IMAGE_SET} AND zone:${REGION}" --format='table[no-heading](name)')"
  if [ -n "${OLD_INSTANCES}" ]; then
    log "Found old instances:" $OLD_INSTANCES
  else
    log "WARNING: No old instances found"
  fi

  log "Querying previous images..."
  OLD_IMAGES="$(retry gcloud compute images list --project="${GCP_PROJECT}" --filter="labels.image-set=${IMAGE_SET}" --format='table[no-heading](name)')"
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
    retry gcloud compute instances delete ${OLD_INSTANCES} --zone="${REGION}" --delete-disks=all --project="${GCP_PROJECT}" --quiet
  else
    log "No previous instances to terminate."
  fi

  # delete old images
  if [ -n "${OLD_IMAGES}" ]; then
    log "Deleting the old image(s) ("${OLD_IMAGES}")..."
    retry gcloud compute images delete ${OLD_IMAGES} --project="${GCP_PROJECT}" --quiet
  else
    log "No old images to delete."
  fi
}

function google_update {

  # NOTE: to grant permission for community-tc worker manager to use images in your GCP project, run:
  # gcloud projects add-iam-policy-binding "${GCP_PROJECT}" --member serviceAccount:taskcluster-worker-manager@taskcluster-temp-workers.iam.gserviceaccount.com --role roles/compute.imageUser

  # Prefer no ssh keys, see: https://cloud.google.com/compute/docs/instances/adding-removing-ssh-keys

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

  retry gcloud compute --project="${GCP_PROJECT}" instances create "${UNIQUE_NAME}" --description="instance for image set ${IMAGE_SET}" --zone="${REGION}" --machine-type="$(cat gcp_base_instance_type)" --subnet=default --network-tier=PREMIUM --metadata-from-file="${STARTUP_KEY}=${TEMP_SETUP_SCRIPT}" --no-restart-on-failure --maintenance-policy=MIGRATE --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append $(cat gcp_filters) --boot-disk-device-name="${UNIQUE_NAME}" --labels="image-set=${IMAGE_SET}" --reservation-affinity=any

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

  log "Now creating an image from the stopped instance..."
  # gcloud compute disks snapshot "${UNIQUE_NAME}" --project="${GCP_PROJECT}" --description="my description" --labels="key1=value1" --snapshot-names="${UNIQUE_NAME}" --zone="${REGION}" --storage-location=us
  retry gcloud compute images create "${UNIQUE_NAME}" --source-disk="${UNIQUE_NAME}" --source-disk-zone="${REGION}" --labels="image-set=${IMAGE_SET}" --project="${GCP_PROJECT}"

  log ''
  log "The image is being created here:"
  log ''
  log "                         https://console.cloud.google.com/compute/imagesDetail/projects/${GCP_PROJECT}/global/images/${UNIQUE_NAME}?project=${GCP_PROJECT}&authuser=1&supportedpurview=project"

  until [ "$(gcloud compute --project="${GCP_PROJECT}" images describe "${UNIQUE_NAME}" --format='table[no-heading](status)')" == 'READY' ]; do
    log "    Waiting for image ${UNIQUE_NAME} to be created..."
    sleep 15
  done

  log "Now deleting the stopped instance..."
  retry gcloud compute --project="${GCP_PROJECT}" instances delete --zone="${REGION}" "${UNIQUE_NAME}" --quiet

  echo "projects/${GCP_PROJECT}/global/images/${UNIQUE_NAME}" > gcp.secrets
}

################## AZURE ##################

function azure_delete {
  azure_find_old_objects
  azure_delete_found
  azure_delete_resource_groups
}

function azure_find_old_objects {
  log "Querying previous images..."
  OLD_IMAGES="$(retry az image list --query="[?tags.image_set == '${IMAGE_SET}' && location == '${REGION}'].id" --output tsv)"
  if [ -n "${OLD_IMAGES}" ]; then
    log "Found old image(s):" $OLD_IMAGES
  else
    log "WARNING: No old images found"
  fi
}

function azure_delete_found {
  if [ -n "${OLD_IMAGES}" ]; then
    log "Deleting the old image(s) ("${OLD_IMAGES}")..."
    log-iff-fails retry az image delete --ids ${OLD_IMAGES} --no-wait true
  else
    log "No old images to delete."
  fi
}

function azure_delete_resource_groups {
  log "Querying old resource groups..."
  OLD_RESOURCE_GROUPS="$(retry az group list --query="[?tags.image_set == '${IMAGE_SET}' && location == '${REGION}'].id" --output tsv)"
  if [ -n "${OLD_RESOURCE_GROUPS}" ]; then
    log "Found old resource group(s):" $OLD_RESOURCE_GROUPS
  else
    log "WARNING: No old resource groups found"
  fi
  if [ -n "${OLD_RESOURCE_GROUPS}" ]; then
    for group in ${OLD_RESOURCE_GROUPS}; do
      log "Now deleting previous resource group ${group}..."
      log-iff-fails retry az group delete --name="${group}" --yes --no-wait
    done
  else
    log "No previous resource groups to delete."
  fi
}

function azure_update {

  # Note, we could haved alternatively checked availability of the given
  # machine type in the given location by querying the file database in
  # /config/azure-vm-size-offerings directory, but that may be out-of-date
  # and this az cli call is pretty quick to make anyway.
  if [ -z "$(retry az vm list-skus --location "${REGION}" --resource-type virtualMachines --query="[].name" --output tsv | sed -n "/^$(cat azure_base_instance_type)\$/p")" ]; then
    log "Cannot deploy in ${REGION} since machine type $(cat azure_base_instance_type) is not supported; skipping."
    return 0
  fi

  # Avoid using UNIQUE_NAME which may be too long, see e.g.
  # https://bugs.launchpad.net/ubuntu-kernel-tests/+bug/1779107/comments/2
  NAME_WITH_REGION="imageset-${UUID}-${REGION}"
  TEMP_SETUP_SCRIPT="$(mktemp -t ${NAME_WITH_REGION}.XXXXXXXXXX)"

  cat bootstrap.ps1 | sed 's/%MY_CLOUD%/azure/g' >> "${TEMP_SETUP_SCRIPT}"

  AZURE_VM_RESOURCE_GROUP="${NAME_WITH_REGION}-rg"

  log "Creating temporary resource group ${AZURE_VM_RESOURCE_GROUP} for image building resources..."
  log-iff-fails retry az group create \
    --name="${AZURE_VM_RESOURCE_GROUP}" \
    --tags "image_set=${IMAGE_SET}" \
    --location="${REGION}"

  # The admin password needs to contain 3 of the 4 character ranges specified
  # in the loop below. To ensure characters from all ranges are present, choose 5
  # characters randomly from each range.
  ADMIN_PASSWORD=''
  for range in 'A-Z' 'a-z' '0-9' '!@#$%^&*'; do
    ADMIN_PASSWORD="${ADMIN_PASSWORD}$(head -c 256 /dev/urandom | LC_ALL=C tr -dc "${range}" | head -c 5)"
  done

  log "Creating instance ${NAME_WITH_REGION}..."
  log-iff-fails retry az vm create \
    --name="${NAME_WITH_REGION}" \
    --image=$(cat azure_image) \
    --resource-group="${AZURE_VM_RESOURCE_GROUP}" \
    --computer-name="ImageBuilder" \
    --os-disk-delete-option=Delete \
    --data-disk-delete-option=Delete \
    --nic-delete-option=Delete \
    --nsg-rule=NONE \
    --license-type="Windows_Server" \
    --accept-term \
    --location="${REGION}" \
    --security-type="Standard" \
    --size=$(cat azure_base_instance_type) \
    --tags "image_set=${IMAGE_SET}" \
    --admin-username="azureuser" \
    --admin-password="${ADMIN_PASSWORD}"

  PUBLIC_IP="$(retry az vm show -d --name="${NAME_WITH_REGION}" --resource-group="${AZURE_VM_RESOURCE_GROUP}" --query publicIps --output tsv)"

  log "Created instance ${NAME_WITH_REGION}."

  log "To connect to the template instance (please don't do so until image creation process is completed"'!'"):"
  log ''
  log "                         Public IP:   ${PUBLIC_IP}"
  log "                         Username:    azureuser"
  log "                         Password:    ${ADMIN_PASSWORD}"
  log ''

  log "Running bootstrap script - it can take a \x1B[4mVery Long Time™\x1B[24m..."
  retry az vm run-command invoke \
    --command-id="RunPowerShellScript" \
    --name="${NAME_WITH_REGION}" \
    --resource-group="${AZURE_VM_RESOURCE_GROUP}" \
    --scripts="@${TEMP_SETUP_SCRIPT}" \
    --no-wait
  rm "${TEMP_SETUP_SCRIPT}"

  log "Waiting for instance ${NAME_WITH_REGION} to shut down..."
  retry az vm wait \
    --custom="instanceView.statuses[?code=='PowerState/stopped']" \
    --name="${NAME_WITH_REGION}" \
    --resource-group="${AZURE_VM_RESOURCE_GROUP}" \
    --interval=15

  log "Starting instance ${NAME_WITH_REGION} to run sysprep..."
  retry az vm start \
    --name="${NAME_WITH_REGION}" \
    --resource-group="${AZURE_VM_RESOURCE_GROUP}"

  log "Running Sysprep on instance ${NAME_WITH_REGION}..."
  retry az vm run-command invoke \
    --command-id="RunPowerShellScript" \
    --name="${NAME_WITH_REGION}" \
    --resource-group="${AZURE_VM_RESOURCE_GROUP}" \
    --scripts @sysprep.ps1 \
    --no-wait

  log "Waiting for instance ${NAME_WITH_REGION} to shut down..."
  retry az vm wait \
    --custom="instanceView.statuses[?code=='PowerState/stopped']" \
    --name="${NAME_WITH_REGION}" \
    --resource-group="${AZURE_VM_RESOURCE_GROUP}" \
    --interval=15

  log "Generalizing VM to allow it to be imaged..."
  retry az vm generalize \
    --name="${NAME_WITH_REGION}" \
    --resource-group="${AZURE_VM_RESOURCE_GROUP}"

  log "Deallocating VM..."
  retry az vm deallocate \
    --name="${NAME_WITH_REGION}" \
    --resource-group="${AZURE_VM_RESOURCE_GROUP}"

  log "Creating an image from the terminated instance..."
  log-iff-fails retry az image create \
    --name="${NAME_WITH_REGION}" \
    --resource-group="${AZURE_VM_RESOURCE_GROUP}" \
    --hyper-v-generation="V2" \
    --location="${REGION}" \
    --tags "image_set=${IMAGE_SET}" \
    --source="${NAME_WITH_REGION}"

  IMAGE_ID="$(retry az image show --name="${NAME_WITH_REGION}" --resource-group="${AZURE_VM_RESOURCE_GROUP}" --query id --output tsv)"

  log ''
  log "The image is being created here:"
  log ''
  log "                         https://portal.azure.com/#@mozilla.com/resource${IMAGE_ID}"
  log ''

  log "Waiting for image ${NAME_WITH_REGION} to be created..."
  retry az image wait \
    --created \
    --image-name="${NAME_WITH_REGION}" \
    --resource-group="${AZURE_VM_RESOURCE_GROUP}" \
    --interval=15

  # Try to acquire an exclusive lock as only one `az resource move` can happen
  # at a time. Place lock in parent folder so the lock is shared across all
  # image sets, otherwise it appears image sets cannot be built in parallel.
  exec 200> ../azure_move_image.lock
  flock -x 200

  log "Moving image ${NAME_WITH_REGION} to ${AZURE_IMAGE_RESOURCE_GROUP} resource group..."
  retry az resource move \
    --destination-group="${AZURE_IMAGE_RESOURCE_GROUP}" \
    --ids="${IMAGE_ID}"

  # Release the lock
  flock -u 200

  log "Deleting temporary resource group ${AZURE_VM_RESOURCE_GROUP}..."
  log-iff-fails retry az group delete --name="${AZURE_VM_RESOURCE_GROUP}" --yes --no-wait

  IMAGE_ID="$(retry az image show --name="${NAME_WITH_REGION}" --resource-group="${AZURE_IMAGE_RESOURCE_GROUP}" --query id --output tsv)"

  {
    echo "Instance:  ${NAME_WITH_REGION}"
    echo "Public IP: ${PUBLIC_IP}"
    echo "Username:  azureuser"
    echo "Password:  ${ADMIN_PASSWORD}"
    echo "Image:     ${IMAGE_ID}"
  } > "azure.${REGION}.secrets"
}

############### Deploy all image sets ###############

function all-in-parallel {
  : ${BUILD_IMAGES:=true}
  : ${BUILD_STAGING_IMAGES:=false}
  : ${DELETE_OLD_RGS:=true}

  : ${DEPLOY_IMAGES:=true}
  : ${DEPLOY_MACS:=true}

  : ${LOGIN_AWS:=true}
  : ${LOGIN_AZURE:=true}

  : ${UPDATE_GCLOUD:=true}
  : ${UPDATE_OFFERINGS:=true}
  : ${AZURE_VM_SIZES_PARALLEL_PROCESSES:=10}
  : ${UPDATE_TASKCLUSTER_VERSION:=true}

  : ${USE_LATEST_TASKCLUSTER_VERSION:=true}

  export GCP_PROJECT=community-tc-workers
  export AZURE_IMAGE_RESOURCE_GROUP=rg-tc-eng-images

  export TASKCLUSTER_CLIENT_ID='static/taskcluster/root'
  export TASKCLUSTER_ROOT_URL='https://community-tc.services.mozilla.com'
  unset TASKCLUSTER_CERTIFICATE

  if "${LOGIN_AZURE}"; then
    retry az login
  fi

  if "${DELETE_OLD_RGS}"; then
    for rg in $(az group list --query "[?starts_with(name, 'imageset-')].name" -o tsv); do
      echo "Deleting old resource group ${rg}..."
      az group delete --name $rg --yes --no-wait
    done
  fi

  if "${UPDATE_GCLOUD}"; then
    retry gcloud components update -q
  fi
  retry gcloud auth login

  PREP_DIR="$(mktemp -t deploy-worker-pools.XXXXXXXXXX -d)"
  cd "${PREP_DIR}"

  echo
  echo "Preparing in directory ${PREP_DIR}..."
  echo

  if "${USE_LATEST_TASKCLUSTER_VERSION}"; then
    VERSION="$(retry curl https://api.github.com/repos/taskcluster/taskcluster/releases/latest 2>/dev/null | jq -r .tag_name)"
    if [ -z "${VERSION}" ]; then
      echo "Cannot retrieve latest taskcluster version" >&2
      return 64
    fi
  fi
  if "${UPDATE_TASKCLUSTER_VERSION}" && [ -z "${VERSION}" ]; then
    echo "No taskcluster version specified" >&2
    return 75
  fi

  mkdir tc-admin

  cd tc-admin
  python3 -m venv tc-admin-venv
  source tc-admin-venv/bin/activate
  pip3 install pytest
  pip3 install --upgrade pip

  cd "${IMAGESETS_DIR}/.."

  pip3 install -e .
  which tc-admin
  export TASKCLUSTER_ACCESS_TOKEN="$(pass ls community-tc/root | head -1)"

  if "${LOGIN_AWS}"; then
    eval $(imagesets/signin-aws.sh)
  fi

  if "${UPDATE_OFFERINGS}"; then
    echo "Updating EC2 instance types..."
    misc/update-ec2-instance-types.sh
    git add 'config/ec2-instance-type-offerings'
    git commit -m "Ran script misc/update-ec2-instance-types.sh" || true

    echo "Updating Azure VM sizes..."
    misc/update-azure-vm-sizes.sh "${AZURE_VM_SIZES_PARALLEL_PROCESSES}"
    git add 'config/azure-vm-size-offerings'
    git commit -m "Ran script misc/update-azure-vm-sizes.sh" || true

    echo "Updating GCE machine types..."
    misc/update-gce-machine-types.sh
    git add 'config/gce-machine-type-offerings.json'
    git commit -m "Ran script misc/update-gce-machine-types.sh" || true

    retry git push "${OFFICIAL_GIT_REPO}"
    retry tc-admin apply
  fi

  if "${UPDATE_TASKCLUSTER_VERSION}"; then
    cd imagesets
    git ls-files | grep -F 'bootstrap.' | while read file; do
      cat "${file}" > "${file}.bak"
      cat "${file}.bak" | sed 's/^ *setenv TASKCLUSTER_VERSION .*/setenv TASKCLUSTER_VERSION '"${VERSION}"'/' \
        | sed 's/^ *TASKCLUSTER_VERSION=.*/TASKCLUSTER_VERSION='"'${VERSION}'"'/' \
        | sed 's/^ *\$TASKCLUSTER_VERSION *=.*/$TASKCLUSTER_VERSION = "'"${VERSION}"'"/' \
        > "${file}"
      rm "${file}.bak"
      git add "${file}"
    done
    git commit -m "chore: bump to TC ${VERSION}" || true
    retry git push "${OFFICIAL_GIT_REPO}"
    cd ..
  fi

  #######################################################################################
  ######## Comment out image sets / macOS workers that don't need to be updated! ########
  #######################################################################################


  ##################################
  ###### Update macOS workers ######
  ##################################
  #
  # Remember to connect to the mozilla VPN before running this script in order to access the mac minis!
  # Remeber to vnc as administrator onto macs before running this script, to avoid ssh connection problems!

  # TODO: fetch these IPs automatically, and report if they need to be logged into first with vnc
  if "${DEPLOY_MACS}"; then
    for HOST in macmini-m4-1 macmini-m4-2; do
      pass "macstadium/generic-worker-ci/${HOST}" | tail -1 | ssh "administrator@${HOST}.test.releng.mslv.mozilla.com" sudo -S "bash" -c /var/root/update.sh
    done
  fi


  if "${BUILD_IMAGES}"; then
    # TODO: inspect configs to determine full set of image sets to build, rather than maintain a static list

    ########## Azure Windows ##########
    # imagesets/imageset.sh azure update generic-worker-win2022 &
    # imagesets/imageset.sh azure update generic-worker-win2022-gpu &

    ########## Non-Azure Windows ##########
    # Commenting out for now due to https://github.com/taskcluster/community-tc-config/issues/872
    # and the fact that we no longer run windows workloads on AWS
    # imagesets/imageset.sh aws update generic-worker-win2022 &

    ########## Ubuntu ##########
    imagesets/imageset.sh google update generic-worker-ubuntu-24-04 &
    imagesets/imageset.sh aws update generic-worker-ubuntu-24-04 &
    imagesets/imageset.sh google update generic-worker-ubuntu-24-04-arm64 &

    if "${BUILD_STAGING_IMAGES}"; then
      # imagesets/imageset.sh azure update generic-worker-win2022-staging &
      # imagesets/imageset.sh azure update generic-worker-win2025-staging &
      # imagesets/imageset.sh azure update generic-worker-win2022-gpu-staging &
      # imagesets/imageset.sh azure update generic-worker-win11-24h2-staging &
      imagesets/imageset.sh google update generic-worker-ubuntu-24-04-staging &
      imagesets/imageset.sh aws update generic-worker-ubuntu-24-04-staging &
    fi

    wait

    if "${DELETE_OLD_RGS}"; then
      for rg in $(az group list --query "[?starts_with(name, 'imageset-')].name" -o tsv); do
        echo "Deleting old resource group ${rg}..."
        az group delete --name $rg --yes --no-wait
      done
    fi
    export GITHUB_TOKEN=$(gh auth token)
    python3 imagesets/rel-sre-imagesets.py
    git add config/imagesets.yml
    git commit -m "Built new Azure machine images"
    retry git -c pull.rebase=true pull "${OFFICIAL_GIT_REPO}" main
    retry git push "${OFFICIAL_GIT_REPO}" "+HEAD:refs/heads/main"
  fi

  if "${DEPLOY_IMAGES}"; then
    retry tc-admin apply
  fi

  echo
  echo "Deleting preparation directory: ${PREP_DIR}..."
  echo
  cd
  rm -rf "${PREP_DIR}"
  echo "All done!"
}

################## Entry point ##################

cd "$(dirname "${0}")"

IMAGESETS_DIR="$(pwd)"

export OFFICIAL_GIT_REPO='git@github.com:taskcluster/community-tc-config'

if [ "${1-}" == "all" ]; then
  all-in-parallel
  exit 0
fi

if [ "${1-}" == "process-region" ]; then
  # Step into directory containing image set definition.
  cd "${IMAGE_SET}"
  REGION="${3}"
  FOREGROUND_COLOUR="${4}"
  BACKGROUND_COLOUR="${5}"
  "${2}"
  exit 0
fi

deploy "${@}"
