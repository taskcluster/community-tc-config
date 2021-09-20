#!/usr/bin/env bash

# This script runs imageset.sh under docker.
# To see how the docker image was created, see the docker subdirectory.
# Parameters passed to this script will be passed on to imageset.sh.

cd "$(dirname "${0}")"
TAG="$(cat docker/TAG)"
docker run \
    --rm \
    -ti \
    -v "$(pwd)/..:/community-tc-config" \
    -v ~/.aws:/root/.aws \
    -v ~/.config:/root/.config \
    -v ~/.gitconfig:/root/.gitconfig \
    -v ~/.gnupg:/root/.gnupg \
    -v ~/.ssh:/root/.ssh \
    -e AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY \
    -e AWS_SESSION_TOKEN \
    -e GCP_PROJECT \
    "${TAG}" \
    /community-tc-config/imagesets/imageset.sh "${@}"
