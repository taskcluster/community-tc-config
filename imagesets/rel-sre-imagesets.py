#!/usr/bin/env python3
import os
import time
import requests
import re
from ruamel.yaml import YAML

# ---- Config ----
REPO = "mozilla-platform-ops/worker-images"
WORKFLOW_FILE = "nonsig-tceng-azure.yml"
REF = "main"
CONFIGS = [
    "generic-worker-win2022-staging",
    "generic-worker-win2022",
    "generic-worker-win2022-gpu-staging",
    "generic-worker-win2022-gpu",
    "generic-worker-win11-24h2-staging",
    "generic-worker-win2025-staging",
]
IMAGESETS_FILE = "config/imagesets.yml"

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN")
HEADERS = {"Authorization": f"Bearer {GITHUB_TOKEN}"}
API_ROOT = "https://api.github.com"

yaml = YAML()
yaml.preserve_quotes = True


# ---- Workflow Helpers ----
def trigger_workflow(config):
    url = f"{API_ROOT}/repos/{REPO}/actions/workflows/{WORKFLOW_FILE}/dispatches"
    response = requests.post(
        url,
        headers=HEADERS,
        json={"ref": REF, "inputs": {"config": config}},
    )
    response.raise_for_status()
    print(f"🚀 Triggered workflow for config={config}")


def get_recent_runs():
    url = f"{API_ROOT}/repos/{REPO}/actions/runs"
    response = requests.get(url, headers=HEADERS)
    response.raise_for_status()
    return response.json()["workflow_runs"]


def wait_for_runs(run_numbers):
    print("⏳ Waiting for workflow runs to complete...")
    unfinished = set(run_numbers)
    while unfinished:
        time.sleep(30)
        for run_number in list(unfinished):
            run = next((r for r in get_recent_runs() if r["run_number"] == run_number), None)
            if not run:
                continue
            if run["status"] == "completed":
                print(f"   → Run #{run_number} finished with conclusion={run['conclusion']}")
                unfinished.remove(run_number)
    print("✅ All runs completed.")


# ---- Existing Helpers (unchanged, except RUN_NUMBERS removed) ----
def get_real_run_id(run_number):
    runs = get_recent_runs()
    for run in runs:
        if run["run_number"] == run_number:
            return run["id"]
    raise ValueError(f"No run ID found for run_number {run_number}")


def get_workflow_jobs(run_id):
    url = f"{API_ROOT}/repos/{REPO}/actions/runs/{run_id}/jobs"
    response = requests.get(url, headers=HEADERS)
    response.raise_for_status()
    return response.json()["jobs"]


def download_job_log(job_id):
    url = f"{API_ROOT}/repos/{REPO}/actions/jobs/{job_id}/logs"
    response = requests.get(url, headers=HEADERS)
    response.raise_for_status()
    return response.content.decode("utf-8")


def extract_image_name(log):
    match = re.search(r"Image Name\s+: '([^']+)'", log)
    return match.group(1) if match else None


def parse_job_name(name):
    parts = name.split(" - ")
    if len(parts) != 2:
        return None, None
    return parts[0].strip(), parts[1].strip()


def update_yaml_file_bulk(data, image_set, region_to_image):
    try:
        images_node = data[image_set]["azure"]["images"]
    except KeyError:
        print(f"      ❌ {image_set}.azure.images not found in YAML, skipping.")
        return False

    if not images_node:
        print(f"      ⚠️ No existing entries for {image_set}.azure.images, skipping clear.")
        return False

    sample_path = next(iter(images_node.values()))
    prefix = "/".join(sample_path.split("/")[:-1])

    print(f"      🧹 Clearing old entries under {image_set}.azure.images")
    images_node.clear()

    for region, new_image in region_to_image.items():
        if not new_image.startswith("imageset-"):
            print(f"      ❌ New image '{new_image}' does not start with 'imageset-', skipping {region}.")
            continue

        new_path = f"{prefix}/{new_image}"
        images_node[region] = new_path
        print(f"      ✅ Set {region} = {new_path}")

    return True


# ---- Main ----
def main():
    assert GITHUB_TOKEN, "Set the GITHUB_TOKEN environment variable"

    # 1. Trigger workflows
    before = {r["run_number"] for r in get_recent_runs()}
    for cfg in CONFIGS:
        trigger_workflow(cfg)

    # 2. Get new run numbers
    time.sleep(5)  # allow GH to register
    after = {r["run_number"] for r in get_recent_runs()}
    new_runs = sorted(after - before)
    print(f"🎯 New workflow run numbers: {new_runs}")

    # 3. Wait for completion
    wait_for_runs(new_runs)

    # 4. Process jobs (existing logic)
    with open(IMAGESETS_FILE, "r") as f:
        data = yaml.load(f)

    staged_updates = {}
    updated = False
    for run_number in new_runs:
        try:
            run_id = get_real_run_id(run_number)
        except ValueError as e:
            print(f"⚠️  {e}")
            continue

        print(f"\n🔍 Processing workflow run #{run_number} (ID: {run_id})")
        jobs = get_workflow_jobs(run_id)

        for job in jobs:
            job_name = job["name"]
            if " - " not in job_name:
                continue
            image_set, region = parse_job_name(job_name)
            if not image_set or not region:
                continue

            log = download_job_log(job["id"])
            image_name = extract_image_name(log)
            if not image_name:
                continue

            staged_updates.setdefault(image_set, {})[region] = image_name

    for image_set, region_to_image in staged_updates.items():
        if update_yaml_file_bulk(data, image_set, region_to_image):
            updated = True

    if updated:
        with open(IMAGESETS_FILE, "w") as f:
            yaml.dump(data, f)
        print("\n✅ YAML file written to disk.")
    else:
        print("\nℹ️  No updates were made to the YAML file.")


if __name__ == "__main__":
    main()
