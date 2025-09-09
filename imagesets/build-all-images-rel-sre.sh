#!/bin/bash

cd "$(dirname "${0}")"

gh workflow run nonsig-tceng-azure.yml --ref main -R mozilla-platform-ops/worker-images -f config=generic-worker-win2022-staging
gh workflow run nonsig-tceng-azure.yml --ref main -R mozilla-platform-ops/worker-images -f config=generic-worker-win2022
gh workflow run nonsig-tceng-azure.yml --ref main -R mozilla-platform-ops/worker-images -f config=generic-worker-win2022-gpu-staging
gh workflow run nonsig-tceng-azure.yml --ref main -R mozilla-platform-ops/worker-images -f config=generic-worker-win2022-gpu
gh workflow run nonsig-tceng-azure.yml --ref main -R mozilla-platform-ops/worker-images -f config=generic-worker-win11-24h2-staging
gh workflow run nonsig-tceng-azure.yml --ref main -R mozilla-platform-ops/worker-images -f config=generic-worker-win2025-staging

# TODO: wait for all workflows to complete

export GITHUB_TOKEN=$(gh auth token)
python3 rel-sre-imagesets.py
