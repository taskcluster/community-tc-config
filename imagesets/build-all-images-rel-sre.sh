#!/bin/bash

cd "$(dirname "${0}")"

export GITHUB_TOKEN=$(gh auth token)
python3 rel-sre-imagesets.py
