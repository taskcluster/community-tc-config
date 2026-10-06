#!/usr/bin/env python3
import base64
import os
import time
import requests
import re
import urllib.parse
from datetime import datetime, timezone
from ruamel.yaml import YAML
from requests import Response

# ---- Config ----
REPO = "mozilla-platform-ops/worker-images"
REF = "main"
WORKFLOWS = {
    "nonsig-tceng-azure.yml": [
        "generic-worker-win2022",
        "generic-worker-win2022-gpu",
    ],
    "gcp-tceng.yml": [
        "generic-worker-ubuntu-24-04-arm64",
        "generic-worker-ubuntu-24-04",
    ],
    "aws-tceng.yml": [
        "generic-worker-ubuntu-24-04-arm64",
        "generic-worker-ubuntu-24-04",
    ],
}
IMAGESETS_FILE = "config/imagesets.yml"
# Every file in this worker-images directory that pins `taskcluster_version`
# is bumped to the latest Taskcluster release before building.
TCENG_CONFIG_DIR = "config/tceng"
TASKCLUSTER_VERSION_RE = re.compile(r"^(\s*taskcluster_version:\s*)([\"']?)([^\"'\s#]+)([\"']?)", re.M)
PR_POLL_SECONDS = 60
# Builds occasionally fail transiently (e.g. an Azure VM create that hangs),
# so failed jobs are rerun until a run has had this many attempts.
MAX_RUN_ATTEMPTS = int(os.environ.get("MAX_RUN_ATTEMPTS", "3"))
RERUN_CONCLUSIONS = {"failure", "timed_out"}

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
def gh(url, method="GET", max_retries=5, **kwargs) -> Response:
    """Make a GitHub API request with retry logic for network failures."""
    for attempt in range(max_retries):
        try:
            # Add timeout to prevent hanging indefinitely
            if 'timeout' not in kwargs:
                kwargs['timeout'] = 30
            r = requests.request(method, url, headers=HEADERS, **kwargs)
            r.raise_for_status()
            return r
        except (requests.exceptions.ConnectionError,
                requests.exceptions.Timeout,
                requests.exceptions.ConnectTimeout) as e:
            if attempt < max_retries - 1:
                wait_time = 2 ** attempt  # Exponential backoff: 1s, 2s, 4s, 8s, 16s
                print(f"⚠️  Network error (attempt {attempt + 1}/{max_retries}): {e}")
                print(f"   Retrying in {wait_time}s...")
                time.sleep(wait_time)
            else:
                print(f"❌ Failed after {max_retries} attempts")
                raise
    # This should never be reached due to raise, but satisfies type checker
    raise RuntimeError("Unexpected: max_retries loop completed without return or raise")

def get_cloud_provider(workflow_file: str) -> str:
    """
    Extract cloud provider from workflow filename.
    Examples:
      'nonsig-tceng-azure.yml' -> 'azure'
      'gcp-tceng.yml' -> 'gcp'
      'aws-tceng.yml' -> 'aws'
    """
    if "azure" in workflow_file:
        return "azure"
    elif "gcp" in workflow_file:
        return "gcp"
    elif "aws" in workflow_file:
        return "aws"
    else:
        raise ValueError(f"Unknown cloud provider in workflow file: {workflow_file}")

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
def trigger_workflow(workflow_file, config):
    url = f"{API_ROOT}/repos/{REPO}/actions/workflows/{workflow_file}/dispatches"
    gh(url, "POST", json={"ref": REF, "inputs": {"config": config}})
    print(f"🚀 Triggered workflow {workflow_file} for config={config}")

def list_dispatch_runs_for_workflow(workflow_file, per_page=100):
    url = f"{API_ROOT}/repos/{REPO}/actions/workflows/{workflow_file}/runs"
    r = gh(url, params={"branch": REF, "event": "workflow_dispatch", "per_page": per_page})
    return r.json()["workflow_runs"]

def get_run_status(run_id):
    url = f"{API_ROOT}/repos/{REPO}/actions/runs/{run_id}"
    return gh(url).json()


# ---- Taskcluster version bump ----
def latest_taskcluster_version():
    tag = gh(f"{API_ROOT}/repos/taskcluster/taskcluster/releases/latest").json()["tag_name"]
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)", tag)
    if not match:
        raise SystemExit(f"❌ Unexpected latest Taskcluster release tag: {tag}")
    return match.group(1)

def outdated_tceng_configs(ref, version):
    """{path: new_content} for every file under TCENG_CONFIG_DIR at `ref` whose
    taskcluster_version isn't `version`."""
    listing = gh(f"{API_ROOT}/repos/{REPO}/contents/{TCENG_CONFIG_DIR}", params={"ref": ref}).json()
    changes = {}
    for entry in listing:
        if entry["type"] != "file":
            continue
        url = f"{API_ROOT}/repos/{REPO}/contents/{urllib.parse.quote(entry['path'])}"
        content = base64.b64decode(gh(url, params={"ref": ref}).json()["content"]).decode("utf-8")
        new = TASKCLUSTER_VERSION_RE.sub(lambda m: f"{m.group(1)}{m.group(2)}{version}{m.group(4)}", content)
        if new != content:
            changes[entry["path"]] = new
    return changes

def find_pr(branch):
    owner = REPO.split("/")[0]
    prs = gh(f"{API_ROOT}/repos/{REPO}/pulls",
             params={"head": f"{owner}:{branch}", "state": "all", "per_page": 1}).json()
    return prs[0] if prs else None

def open_bump_pr(version, changes, base_sha):
    branch = f"tceng-tc-v{version}"
    pr = find_pr(branch)
    if pr and pr["state"] == "closed" and not pr["merged_at"]:
        raise SystemExit(f"❌ {pr['html_url']} was closed without merging; reopen it or delete branch {branch}.")
    if pr:
        print(f"♻️  Reusing {pr['html_url']}")
        return pr

    title = f"chore(tceng): bump to TC v{version}"
    base_tree = gh(f"{API_ROOT}/repos/{REPO}/git/commits/{base_sha}").json()["tree"]["sha"]
    tree = gh(f"{API_ROOT}/repos/{REPO}/git/trees", "POST", json={
        "base_tree": base_tree,
        "tree": [{"path": p, "mode": "100644", "type": "blob", "content": c} for p, c in changes.items()],
    }).json()["sha"]
    commit = gh(f"{API_ROOT}/repos/{REPO}/git/commits", "POST", json={
        "message": title, "tree": tree, "parents": [base_sha],
    }).json()["sha"]
    try:
        gh(f"{API_ROOT}/repos/{REPO}/git/refs", "POST", json={"ref": f"refs/heads/{branch}", "sha": commit})
    except requests.exceptions.HTTPError as e:
        if e.response.status_code != 422:
            raise
        # Branch left over from an interrupted run, with no PR: point it at the new commit.
        gh(f"{API_ROOT}/repos/{REPO}/git/refs/heads/{branch}", "PATCH", json={"sha": commit, "force": True})
    pr = gh(f"{API_ROOT}/repos/{REPO}/pulls", "POST", json={
        "title": title, "head": branch, "base": REF,
        "body": f"https://github.com/taskcluster/taskcluster/releases/tag/v{version}",
    }).json()
    print(f"📝 Opened {pr['html_url']}")
    return pr

def wait_for_merge(pr):
    if pr["merged_at"]:
        return
    print(f"⏸️  {pr['html_url']} needs to be merged before images can be built.")
    print(f"   Waiting for it to be merged (checking every {PR_POLL_SECONDS}s)...")
    while True:
        time.sleep(PR_POLL_SECONDS)
        try:
            pr = gh(pr["url"]).json()
        except requests.exceptions.RequestException as e:
            print(f"⚠️  Couldn't check PR, will retry: {e}")
            continue
        if pr["merged_at"]:
            print(f"✅ {pr['html_url']} merged.")
            return
        if pr["state"] == "closed":
            raise SystemExit(f"❌ {pr['html_url']} was closed without merging.")

def bump_taskcluster_version():
    """Make every TCEng config on worker-images' main pin the latest Taskcluster
    release, via a PR that must be merged before continuing."""
    version = latest_taskcluster_version()
    base_sha = gh(f"{API_ROOT}/repos/{REPO}/git/ref/heads/{REF}").json()["object"]["sha"]
    changes = outdated_tceng_configs(base_sha, version)
    if not changes:
        print(f"✅ {REPO} {TCENG_CONFIG_DIR} already pins Taskcluster v{version}")
        return
    print(f"⬆️  Bumping to Taskcluster v{version}: {', '.join(sorted(changes))}")
    wait_for_merge(open_bump_pr(version, changes, base_sha))
    base_sha = gh(f"{API_ROOT}/repos/{REPO}/git/ref/heads/{REF}").json()["object"]["sha"]
    still = outdated_tceng_configs(base_sha, version)
    if still:
        raise SystemExit(f"❌ {REF} still doesn't pin v{version} after merge: {', '.join(sorted(still))}")


# ---- Selection / matching ----
def find_new_run_by_config(workflow_file, config, seen_ids):
    """
    Return the most recent workflow_dispatch run whose parsed title config matches exactly,
    created strictly after SCRIPT_START_TIME and not already seen.
    """
    runs = list_dispatch_runs_for_workflow(workflow_file, per_page=100)
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


def trigger_all_workflows(workflows_dict):
    """
    Trigger all configs across all workflows in parallel.
    Returns a dict mapping (workflow_file, config) -> (run_id, run_number, workflow_file)
    """
    run_map = {}  # (workflow_file, config) -> (run_id, run_number, workflow_file)
    seen_ids = set()

    # Phase 1: Trigger new runs for all workflows
    print("🚀 Phase 1: Triggering new builds...")
    for workflow_file, configs in workflows_dict.items():
        print(f"\n{'='*80}")
        print(f"📋 Workflow: {workflow_file}")
        print(f"{'='*80}")
        for cfg in configs:
            print(f"🔧 Preparing {cfg} for {workflow_file} ...")
            trigger_workflow(workflow_file, cfg)

    # Phase 2: Poll for all triggered runs to appear
    print("\n\n⏳ Phase 2: Polling for newly triggered runs to appear...")
    pending_configs = [(wf, cfg) for wf, cfgs in workflows_dict.items() for cfg in cfgs]

    for _ in range(30):  # up to ~90s
        if not pending_configs:
            break

        time.sleep(3)
        remaining = []

        for workflow_file, cfg in pending_configs:
            run = find_new_run_by_config(workflow_file, cfg, seen_ids)
            if run:
                run_map[(workflow_file, cfg)] = (run["id"], run["run_number"], workflow_file)
                seen_ids.add(run["id"])
                print(f"🎯 Matched {cfg} ({workflow_file}): run_id={run['id']} run_number={run['run_number']}")
            else:
                remaining.append((workflow_file, cfg))

        pending_configs = remaining

    if pending_configs:
        print(f"⚠️  Could not find runs for {len(pending_configs)} config(s):")
        for wf, cfg in pending_configs:
            print(f"   - {cfg} ({wf})")

    return run_map

def wait_for_all_runs(run_map):
    """
    Wait for all runs across all workflows to complete.
    run_map: dict[(workflow_file, config)] = (run_id, run_number, workflow_file)
    Returns: dict[(workflow_file, config)] -> (run_id, run_number, conclusion, workflow_file)
    """
    unfinished = dict(run_map)  # (workflow_file, config) -> (run_id, run_number, workflow_file)
    results = {}  # (workflow_file, config) -> (run_id, run_number, conclusion, workflow_file)
    min_attempt = {}  # run_id -> attempt that must complete before the run counts as finished

    print("\n\n⏳ Phase 3: Waiting for all workflow runs to complete...")
    print(f"Monitoring {len(unfinished)} run(s)...\n")

    while unfinished:
        while unfinished:
            time.sleep(20)
            for (workflow_file, cfg), (run_id, run_number, _) in list(unfinished.items()):
                run = get_run_status(run_id)
                # After requesting a rerun, the previous attempt still shows as completed for a while
                if run["status"] != "completed" or run["run_attempt"] < min_attempt.get(run_id, 1):
                    continue
                conclusion = run["conclusion"]
                if conclusion in RERUN_CONCLUSIONS and run["run_attempt"] < MAX_RUN_ATTEMPTS:
                    print(f"   🔁 {cfg} ({workflow_file}): run #{run_number} attempt {run['run_attempt']} "
                          f"finished with conclusion={conclusion}; rerunning failed jobs")
                    gh(f"{API_ROOT}/repos/{REPO}/actions/runs/{run_id}/rerun-failed-jobs", method="POST")
                    min_attempt[run_id] = run["run_attempt"] + 1
                    continue
                results[(workflow_file, cfg)] = (run_id, run_number, conclusion, workflow_file)
                print(f"   ✅ {cfg} ({workflow_file}): run #{run_number} finished with conclusion={conclusion}")
                unfinished.pop((workflow_file, cfg))

        # A finished run may since have been rerun by hand; wait for that too
        for (workflow_file, cfg), (run_id, run_number, _, _) in list(results.items()):
            run = get_run_status(run_id)
            if run["status"] != "completed":
                print(f"   🔁 {cfg} ({workflow_file}): run #{run_number} was rerun (attempt {run['run_attempt']}); waiting for it")
                unfinished[(workflow_file, cfg)] = results.pop((workflow_file, cfg))[:2] + (workflow_file,)

    print("\n✅ All runs completed!")
    return results


# ---- Imagesets logic ----
def get_workflow_jobs(run_id):
    url = f"{API_ROOT}/repos/{REPO}/actions/runs/{run_id}/jobs"
    return gh(url).json()["jobs"]

def download_job_log(job_id):
    url = f"{API_ROOT}/repos/{REPO}/actions/jobs/{job_id}/logs"
    return gh(url).content.decode("utf-8")

def extract_image_name(log, cloud_provider):
    """
    Extract image name/ID from build logs based on cloud provider.

    Azure (uses "images" key with paths): Image Name     : 'imageset-...'
    GCP (uses "image" key, no paths): A disk image was created in the 'taskcluster-imaging' project: generic-worker-ubuntu-24-04...
    AWS (uses "amis" key, no paths): Returns a dict of {region: ami-id} from comma-separated format
                                     eu-west-1:ami-...,us-east-1:ami-...,us-west-2:ami-...
    """
    if cloud_provider == "azure":
        match = re.search(r"Image Name\s+: '([^']+)'", log)
        return match.group(1) if match else None
    elif cloud_provider == "gcp":
        match = re.search(r"A disk image was created in the '[^']+' project: ([^\s]+)", log)
        return match.group(1) if match else None
    elif cloud_provider == "aws":
        match = re.search(r"AMI ID: (.+)", log)
        if match:
            # Parse format: eu-west-1:ami-...,us-east-1:ami-...,us-west-2:ami-...
            ami_string = match.group(1).strip()
            ami_dict = {}
            for pair in ami_string.split(','):
                region, ami_id = pair.strip().split(':', 1)
                ami_dict[region] = ami_id
            return ami_dict
        return None
    else:
        raise ValueError(f"Unknown cloud provider: {cloud_provider}")

def parse_job_name(name):
    parts = name.split(" - ")
    if len(parts) != 2:
        return None, None
    return parts[0].strip(), parts[1].strip()

def update_yaml_file_bulk(data, image_set, cloud_provider, region_to_image):
    # Different cloud providers use different keys
    if cloud_provider == "aws":
        key = "amis"
    elif cloud_provider == "gcp":
        key = "image"
    else:  # azure
        key = "images"

    try:
        images_node = data[image_set][cloud_provider]
    except KeyError:
        print(f"      ❌ {image_set}.{cloud_provider} not found in YAML, skipping.")
        return False

    # GCP uses a single value, not a dict
    if cloud_provider == "gcp":
        if key not in images_node:
            print(f"      ❌ {image_set}.{cloud_provider}.{key} not found in YAML, skipping.")
            return False
        # region_to_image has one entry with key "__single__"
        new_image = region_to_image.get("__single__")
        if not new_image:
            print(f"      ❌ No image name provided for GCP")
            return False
        # Get the path prefix from existing value
        old_image = images_node[key]
        if "/" in old_image:
            prefix = "/".join(old_image.split("/")[:-1])
            new_path = f"{prefix}/{new_image}"
        else:
            new_path = new_image
        images_node[key] = new_path
        print(f"      ✅ Set {key} = {new_path}")
        return True

    # For AWS and Azure, it's a dict
    if key not in images_node:
        print(f"      ❌ {image_set}.{cloud_provider}.{key} not found in YAML, skipping.")
        return False

    images_node = images_node[key]
    if not images_node:
        print(f"      ⚠️ No existing entries for {image_set}.{cloud_provider}.{key}, skipping clear.")
        return False

    # For Azure, get the path prefix BEFORE clearing (e.g., "/subscriptions/.../resourceGroups/.../...")
    path_prefix = None
    if cloud_provider == "azure":
        sample_path = next(iter(images_node.values()), None)
        if sample_path and "/" in sample_path:
            path_prefix = "/".join(sample_path.split("/")[:-1])

    print(f"      🧹 Clearing old entries under {image_set}.{cloud_provider}.{key}")
    images_node.clear()

    for region, new_image in region_to_image.items():
        if cloud_provider == "aws":
            # AWS AMIs are just ami-ids, no paths
            if not new_image.startswith("ami-"):
                print(f"      ❌ New AMI '{new_image}' does not start with 'ami-', skipping {region}.")
                continue
            images_node[region] = new_image
            print(f"      ✅ Set {region} = {new_image}")
        else:
            # Azure uses imageset- prefix and paths
            if not new_image.startswith("imageset-"):
                print(f"      ❌ New image '{new_image}' does not start with 'imageset-', skipping {region}.")
                continue
            if path_prefix:
                new_path = f"{path_prefix}/{new_image}"
            else:
                new_path = new_image
            images_node[region] = new_path
            print(f"      ✅ Set {region} = {new_path}")

    return True

def write_patch_file(staged_updates, filename="patch.yml"):
    """Write only the updates as a patch for yq merging."""
    with open(filename, "w") as f:
        for (image_set, cloud_provider), region_to_image in staged_updates.items():
            # Different cloud providers use different keys
            if cloud_provider == "aws":
                key = "amis"
            elif cloud_provider == "gcp":
                key = "image"
            else:  # azure
                key = "images"
            f.write(f"{image_set}:\n")
            f.write(f"  {cloud_provider}:\n")

            if cloud_provider == "gcp":
                # GCP uses a single value, not a dict
                new_image = region_to_image.get("__single__", "")
                f.write(f"    {key}: {new_image}\n")
            else:
                # AWS and Azure use dicts
                f.write(f"    {key}:\n")
                for region, new_image in region_to_image.items():
                    f.write(f"      {region}: {new_image}\n")
    print(f"📄 Wrote patch file: {filename}")
    print("💡 Merge it with:")
    print(f"   yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "
          f"{IMAGESETS_FILE} {filename} > tmp.yml && mv tmp.yml {IMAGESETS_FILE}")


# ---- Main ----
def main():
    # 0) Builds use worker-images' main, so it must pin the latest Taskcluster first
    if os.environ.get("UPDATE_TASKCLUSTER_VERSION", "true") == "true":
        bump_taskcluster_version()

    # Only match runs triggered from here on, not any started while waiting for the PR.
    global SCRIPT_START_TIME
    SCRIPT_START_TIME = datetime.now(timezone.utc)

    # 1) Trigger all workflows in parallel and wait for all to complete
    run_map = trigger_all_workflows(WORKFLOWS)

    if not run_map:
        print("❌ No runs were captured; nothing to wait on.")
        return

    all_results = wait_for_all_runs(run_map)

    # 2) Update imagesets.yml based on job logs of the captured runs
    if not all_results:
        print("ℹ️  No runs completed; skipping YAML update.")
        return

    with open(IMAGESETS_FILE, "r") as f:
        data = yaml.load(f)

    staged_updates = {}  # (image_set, cloud_provider) -> {region: image_name}
    updated = False
    failed_jobs = []

    # all_results: (workflow_file, config) -> (run_id, run_number, conclusion, workflow_file)
    for (workflow_file, cfg), (run_id, run_number, _conclusion, _) in all_results.items():
        cloud_provider = get_cloud_provider(workflow_file)
        print(f"\n🔍 Processing workflow run #{run_number} for {cfg} (run_id={run_id}, cloud={cloud_provider})")
        jobs = get_workflow_jobs(run_id)
        print(f"    → Workflow run #{run_number} has {len(jobs)} jobs:")

        for job in jobs:
            job_name = job["name"]
            print(f"      - Job name: '{job_name}'")

            # Parse job name based on cloud provider
            if cloud_provider == "aws":
                # AWS job names: "AWS generic-worker-ubuntu-24-04-arm64"
                if not job_name.startswith("AWS "):
                    print(f"        ⚠️  Skipping non-AWS job")
                    continue
                image_set = job_name[4:].strip()  # Remove "AWS " prefix
                region = None  # AWS regions come from the log output
            elif cloud_provider == "gcp":
                # GCP job names: "GCP generic-worker-ubuntu-24-04-staging"
                if not job_name.startswith("GCP "):
                    print(f"        ⚠️  Skipping non-GCP job")
                    continue
                image_set = job_name[4:].strip()  # Remove "GCP " prefix
                region = None  # GCP uses single image, not per-region
            else:
                # Azure job names: "generic-worker-win2022-staging - eastus"
                if " - " not in job_name:
                    print(f"        ⚠️  Skipping job without region format")
                    continue
                image_set, region = parse_job_name(job_name)
                if not image_set or not region:
                    print(f"        ❌ Could not parse job name, skipping.")
                    continue

            if job["conclusion"] != "success":
                print(f"        ❌ Job finished with conclusion={job['conclusion']}, skipping.")
                failed_jobs.append(f"{job_name} ({job['html_url']})")
                continue

            log = download_job_log(job["id"])
            image_name = extract_image_name(log, cloud_provider)
            if not image_name:
                print(f"        ❌ Image name not found in logs.")
                continue

            key = (image_set, cloud_provider)

            # Handle different cloud provider formats
            if cloud_provider == "aws" and isinstance(image_name, dict):
                # AWS returns a dict of {region: ami_id}
                print(f"        → image_set = '{image_set}', AMIs = {image_name}")
                for ami_region, ami_id in image_name.items():
                    staged_updates.setdefault(key, {})[ami_region] = ami_id
            elif cloud_provider == "gcp":
                # GCP uses a single image value, not per-region
                print(f"        → image_set = '{image_set}', image_name = '{image_name}'")
                staged_updates.setdefault(key, {})["__single__"] = image_name
            else:
                # Azure uses per-region images
                print(f"        → image_set = '{image_set}', region = '{region}', image_name = '{image_name}'")
                staged_updates.setdefault(key, {})[region] = image_name

    if failed_jobs:
        print(f"\n⚠️  {len(failed_jobs)} job(s) didn't succeed (failed jobs are rerun up to {MAX_RUN_ATTEMPTS} attempts); "
              "their regions are dropped from the updated image sets:")
        for failed in failed_jobs:
            print(f"   - {failed}")

    for (image_set, cloud_provider), region_to_image in staged_updates.items():
        if update_yaml_file_bulk(data, image_set, cloud_provider, region_to_image):
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
