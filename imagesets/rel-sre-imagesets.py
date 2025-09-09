import requests
import re
import os
from ruamel.yaml import YAML

# ---- Config ----
REPO = "mozilla-platform-ops/worker-images"
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN")
IMAGESETS_FILE = "config/imagesets.yml"
RUN_NUMBERS = range(46, 52)  # Run numbers like #46–#51
HEADERS = {"Authorization": f"Bearer {GITHUB_TOKEN}"}
API_ROOT = "https://api.github.com"

yaml = YAML()
yaml.preserve_quotes = True

# ---- Helpers ----

def get_real_run_id(run_number):
    url = f"{API_ROOT}/repos/{REPO}/actions/runs"
    response = requests.get(url, headers=HEADERS)
    response.raise_for_status()
    runs = response.json()["workflow_runs"]
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
    """
    Replace ALL entries under <image_set>.azure.images with the new mapping.
    Keeps the existing path prefix, just swaps the image name at the end.
    """
    try:
        images_node = data[image_set]["azure"]["images"]
    except KeyError:
        print(f"      ❌ {image_set}.azure.images not found in YAML, skipping.")
        return False

    if not images_node:
        print(f"      ⚠️ No existing entries for {image_set}.azure.images, skipping clear.")
        return False

    # Derive path prefix from any existing entry
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
    updated = False

    with open(IMAGESETS_FILE, "r") as f:
        data = yaml.load(f)

    # Collect new entries grouped by image_set
    staged_updates = {}

    for run_number in RUN_NUMBERS:
        try:
            run_id = get_real_run_id(run_number)
        except ValueError as e:
            print(f"⚠️  {e}")
            continue

        print(f"\n🔍 Processing workflow run #{run_number} (ID: {run_id})")
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

    # Apply bulk updates per image_set
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

