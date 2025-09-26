#!/usr/bin/env python3
import os
import time
import requests
import re
from datetime import datetime, timezone
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
if not GITHUB_TOKEN:
    raise SystemExit("Set the GITHUB_TOKEN environment variable")
HEADERS = {"Authorization": f"Bearer {GITHUB_TOKEN}"}
API_ROOT = "https://api.github.com"

yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 4096
yaml.indent(mapping=2, sequence=4, offset=2)
yaml.explicit_start = False
yaml.explicit_end = False

# ---- Globals ----
SCRIPT_START_TIME = datetime.now(timezone.utc)


# ---- Utility ----
def gh(url, method="GET", **kwargs):
    r = requests.request(method, url, headers=HEADERS, **kwargs)
    r.raise_for_status()
    return r

def title_to_config(title: str | None) -> str | None:
    """
    Convert a run 'display_title'/'name' like 'TCEng Azure - generic-worker-win2022-staging'
    into just 'generic-worker-win2022-staging'. Falls back to the whole string if unstructured.
    """
    if not title:
        return None
    left, sep, right = title.partition(" - ")
    return (right or title).strip()


# ---- GitHub API helpers ----
def trigger_workflow(config):
    url = f"{API_ROOT}/repos/{REPO}/actions/workflows/{WORKFLOW_FILE}/dispatches"
    gh(url, "POST", json={"ref": REF, "inputs": {"config": config}})
    print(f"🚀 Triggered workflow for config={config}")

def list_dispatch_runs_for_workflow(per_page=100):
    url = f"{API_ROOT}/repos/{REPO}/actions/workflows/{WORKFLOW_FILE}/runs"
    r = gh(url, params={"branch": REF, "event": "workflow_dispatch", "per_page": per_page})
    return r.json()["workflow_runs"]

def cancel_run(run_id):
    url = f"{API_ROOT}/repos/{REPO}/actions/runs/{run_id}/cancel"
    try:
        gh(url, "POST")  # 202 Accepted
        print(f"   🛑 Sent cancel for run_id={run_id}")
    except requests.HTTPError as e:
        # If it already finished between list and cancel, just log and continue
        status = getattr(e.response, "status_code", None)
        print(f"   ⚠️ Cancel failed for run_id={run_id} (status={status}); continuing")

def get_run_status(run_id):
    url = f"{API_ROOT}/repos/{REPO}/actions/runs/{run_id}"
    return gh(url).json()


# ---- Selection / matching ----
def cancel_active_runs_for_config(config):
    """
    Cancel all older active (queued/in_progress) runs whose parsed title config matches exactly.
    """
    runs = list_dispatch_runs_for_workflow(per_page=100)
    active_statuses = {"queued", "in_progress"}
    runs_sorted = sorted(runs, key=lambda r: r["created_at"])  # oldest first for readable logs
    cancelled = 0
    for run in runs_sorted:
        title = run.get("display_title") or run.get("name", "")
        parsed = title_to_config(title)
        status = run.get("status")
        if parsed == config and status in active_statuses:
            print(f"   🔁 Found active older run for {config}: #{run['run_number']} ({status}) created_at={run['created_at']}")
            cancel_run(run["id"])
            cancelled += 1
    if cancelled:
        print(f"   ✅ Cancelled {cancelled} active run(s) for {config}")
    else:
        print(f"   ✅ No active older runs to cancel for {config}")

def find_new_run_by_config(config, seen_ids):
    """
    Return the most recent workflow_dispatch run whose parsed title config matches exactly,
    created strictly after SCRIPT_START_TIME and not already seen.
    """
    runs = list_dispatch_runs_for_workflow(per_page=100)
    for run in sorted(runs, key=lambda r: r["created_at"], reverse=True):
        title = run.get("display_title") or run.get("name", "")
        parsed = title_to_config(title)
        created = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
        if (
            parsed == config
            and run["id"] not in seen_ids
            and created > SCRIPT_START_TIME
        ):
            return run
    return None


def wait_for_runs(run_map):
    """
    run_map: dict[config] = (run_id, run_number)
    """
    unfinished = dict(run_map)  # config -> (id, num)
    results = {}  # config -> (run_id, run_number, conclusion)
    print("⏳ Waiting for workflow runs to complete...")
    while unfinished:
        time.sleep(20)
        for cfg, (run_id, run_number) in list(unfinished.items()):
            run = get_run_status(run_id)
            if run["status"] == "completed":
                conclusion = run["conclusion"]
                results[cfg] = (run_id, run_number, conclusion)
                print(f"   → {cfg}: run #{run_number} finished with conclusion={conclusion}")
                unfinished.pop(cfg)
    print("✅ All runs completed.")
    return results


def trigger_and_wait():
    """
    For each config:
      1) Cancel any older active runs for that exact config.
      2) Trigger a fresh run.
      3) Poll until the *new* run (created after SCRIPT_START_TIME) appears and capture id+number.
    Then wait for all captured runs to complete.
    """
    run_map = {}  # config -> (run_id, run_number)
    seen_ids = set()

    for cfg in CONFIGS:
        print(f"🔧 Preparing {cfg} ...")
        cancel_active_runs_for_config(cfg)
        trigger_workflow(cfg)

        run = None
        for _ in range(30):  # up to ~90s
            time.sleep(3)
            run = find_new_run_by_config(cfg, seen_ids)
            if run:
                break

        if run:
            run_map[cfg] = (run["id"], run["run_number"])
            seen_ids.add(run["id"])
            print(f"🎯 Matched {cfg}: run_id={run['id']} run_number={run['run_number']} (created_at={run['created_at']})")
        else:
            print(f"⚠️ Could not find the new run for {cfg} (yet). Skipping this config.")

    if not run_map:
        print("❌ No runs were captured; nothing to wait on.")
        return {}

    results = wait_for_runs(run_map)
    print("📊 Run summary:")
    for cfg, (_, run_number, conclusion) in results.items():
        print(f"   {cfg}: #{run_number} {conclusion}")
    return results


# ---- Imagesets logic ----
def get_workflow_jobs(run_id):
    url = f"{API_ROOT}/repos/{REPO}/actions/runs/{run_id}/jobs"
    return gh(url).json()["jobs"]

def download_job_log(job_id):
    url = f"{API_ROOT}/repos/{REPO}/actions/jobs/{job_id}/logs"
    return gh(url).content.decode("utf-8")

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

def write_patch_file(staged_updates, filename="patch.yml"):
    """Write only the updates as a patch for yq merging."""
    with open(filename, "w") as f:
        for image_set, region_to_image in staged_updates.items():
            f.write(f"{image_set}:\n")
            f.write("  azure:\n")
            f.write("    images:\n")
            for region, new_image in region_to_image.items():
                f.write(f"      {region}: {new_image}\n")
    print(f"📄 Wrote patch file: {filename}")
    print("💡 Merge it with:")
    print(f"   yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "
          f"{IMAGESETS_FILE} {filename} > tmp.yml && mv tmp.yml {IMAGESETS_FILE}")


# ---- Main ----
def main():
    # 1) Trigger & wait (with cancellation of older active runs)
    results = trigger_and_wait()

    # 2) Update imagesets.yml based on job logs of the captured runs
    if not results:
        print("ℹ️  No runs completed; skipping YAML update.")
        return

    with open(IMAGESETS_FILE, "r") as f:
        data = yaml.load(f)

    staged_updates = {}
    updated = False

    # results: config -> (run_id, run_number, conclusion)
    for cfg, (run_id, run_number, _conclusion) in results.items():
        print(f"\n🔍 Processing workflow run #{run_number} for {cfg} (run_id={run_id})")
        jobs = get_workflow_jobs(run_id)
        print(f"    → Workflow run #{run_number} has {len(jobs)} jobs:")

        for job in jobs:
            job_name = job["name"]
            print(f"      - Job name: '{job_name}'")
            if " - " not in job_name:
                print(f"        ⚠️  Skipping job without region format")
                continue

            image_set, region = parse_job_name(job_name)
            if not image_set or not region:
                print(f"        ❌ Could not parse job name, skipping.")
                continue

            log = download_job_log(job["id"])
            image_name = extract_image_name(log)
            if not image_name:
                print(f"        ❌ Image name not found in logs.")
                continue

            print(f"        → image_set = '{image_set}', region = '{region}', image_name = '{image_name}'")
            staged_updates.setdefault(image_set, {})[region] = image_name

    for image_set, region_to_image in staged_updates.items():
        if update_yaml_file_bulk(data, image_set, region_to_image):
            updated = True

    if updated:
        try:
            with open(IMAGESETS_FILE, "w") as f:
                yaml.dump(data, f)
            print("\n✅ YAML file written to disk with ruamel.yaml.")
            print("   (Run `yamllint` to confirm formatting is acceptable.)")
        except Exception as e:
            print(f"⚠️ Failed to dump YAML cleanly with ruamel.yaml: {e}")
            print("   Falling back to writing patch file instead.")
            write_patch_file(staged_updates)
    else:
        print("\nℹ️  No updates were made to the YAML file.")


if __name__ == "__main__":
    main()
