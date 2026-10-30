#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile
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
# imageset.sh gives gpg the passphrase on this file descriptor
GPG_PASSPHRASE_FDS = (int(os.environ["IMAGESET_GPG_PASSPHRASE_FD"]),) if os.environ.get("IMAGESET_GPG_PASSPHRASE_FD") else ()
# Image sets that worker-images builds for us, per workflow, for each target of
# imageset.sh. Staging builds use the workflows' default TASKCLUSTER_REF (main).
TARGET_WORKFLOWS = {
    "prod": {
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
    },
    "staging": {
        "nonsig-tceng-azure.yml": [
            "generic-worker-win2022-staging",
            "generic-worker-win2022-gpu-staging",
        ],
        "gcp-tceng.yml": [
            "generic-worker-ubuntu-24-04-arm64-staging",
            "generic-worker-ubuntu-24-04-staging",
        ],
        "aws-tceng.yml": [
            "generic-worker-ubuntu-24-04-arm64-staging",
            "generic-worker-ubuntu-24-04-staging",
        ],
    },
}
TARGET_WORKFLOWS["all"] = {}
for _workflows in (TARGET_WORKFLOWS["prod"], TARGET_WORKFLOWS["staging"]):
    for _workflow_file, _configs in _workflows.items():
        TARGET_WORKFLOWS["all"].setdefault(_workflow_file, []).extend(_configs)
TARGET = os.environ.get("IMAGESET_TARGET", "prod")
if TARGET not in TARGET_WORKFLOWS:
    raise SystemExit(f"IMAGESET_TARGET must be one of {', '.join(TARGET_WORKFLOWS)}, not {TARGET!r}")
# The image sets to build and log
WORKFLOWS = TARGET_WORKFLOWS[TARGET]
IMAGESETS_FILE = "config/imagesets.yml"
# Every file in this worker-images directory that pins `taskcluster_version`
# is bumped to the latest Taskcluster release before building.
TCENG_CONFIG_DIR = "config/tceng"
TASKCLUSTER_VERSION_RE = re.compile(r"^(\s*taskcluster_version:\s*)([\"']?)([^\"'\s#]+)([\"']?)", re.M)
PR_POLL_SECONDS = 60
# Builds occasionally fail transiently (e.g. an Azure VM create that hangs, or
# a stuck download), so failed jobs are rerun until a run has had this many
# attempts.
MAX_RUN_ATTEMPTS = int(os.environ.get("MAX_RUN_ATTEMPTS", "5"))
# Where the triggered runs are saved, so that a resumed deployment waits for
# them rather than triggering new ones
RUNS_FILE = os.environ.get("IMAGESET_RUNS_FILE")
RERUN_CONCLUSIONS = {"failure", "timed_out"}
# Jobs that hit their time limit are cancelled with this annotation, so they
# are rerun too, unlike jobs that were cancelled by hand.
TIME_LIMIT_ANNOTATION = "exceeded the maximum execution time"

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN")
if not GITHUB_TOKEN:
    raise SystemExit('Set the GITHUB_TOKEN environment variable, e.g. export GITHUB_TOKEN="$(gh auth token)"')
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
    """Make a GitHub API request with retry logic for network failures and
    server errors."""
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
                requests.exceptions.ConnectTimeout,
                requests.exceptions.HTTPError) as e:
            if isinstance(e, requests.exceptions.HTTPError) and e.response.status_code < 500:
                raise
            if attempt < max_retries - 1:
                wait_time = 2 ** attempt  # Exponential backoff: 1s, 2s, 4s, 8s, 16s
                print(f"⚠️  Request failed (attempt {attempt + 1}/{max_retries}): {e}")
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

def hit_time_limit(run_id):
    """Whether a job of the latest attempt of run `run_id` was cancelled for
    exceeding its time limit (rather than by hand)."""
    for job in get_workflow_jobs(run_id):
        if job["conclusion"] != "cancelled":
            continue
        annotations = gh(f"{API_ROOT}/repos/{REPO}/check-runs/{job['id']}/annotations").json()
        if any(TIME_LIMIT_ANNOTATION in annotation.get("message", "") for annotation in annotations):
            return True
    return False

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

def enable_auto_merge(pr):
    """Have GitHub merge `pr` as soon as it is approved, so that nobody needs to
    come back and merge it after reviewing it."""
    if pr["merged_at"] or pr.get("auto_merge"):
        return
    query = """mutation($id: ID!) {
      enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: MERGE}) { clientMutationId }
    }"""
    try:
        errors = gh(f"{API_ROOT}/graphql", "POST", json={"query": query, "variables": {"id": pr["node_id"]}}).json().get("errors")
    except requests.exceptions.RequestException as e:
        errors = e
    if errors:
        print(f"⚠️  Couldn't enable auto-merge on {pr['html_url']}, it will need merging by hand: {errors}")
    else:
        print(f"🤖 Enabled auto-merge on {pr['html_url']}")

def create_signed_commit(message, tree, parent):
    """Create a commit with the GitHub API, signed with the gpg key that
    imageset.sh signs commits with, as GitHub can't sign it with that key."""
    name, email, key = os.environ["IMAGESET_GIT_NAME"], os.environ["IMAGESET_GIT_EMAIL"], os.environ["IMAGESET_GPG_KEY"]
    if not message.endswith("\n"):
        message += "\n"
    now = int(time.time())
    identity = f"{name} <{email}> {now} +0000"
    headers = f"tree {tree}\nparent {parent}\nauthor {identity}\ncommitter {identity}\n"
    # Signs the commit as git writes it to the object database
    signature = subprocess.run(["gpg", "--local-user", key, "--armor", "--detach-sign"],
                               input=f"{headers}\n{message}".encode(), capture_output=True,
                               pass_fds=GPG_PASSPHRASE_FDS)
    if signature.returncode != 0:
        raise SystemExit(f"❌ Couldn't sign the commit with gpg key {key}:\n{signature.stderr.decode()}")
    signature = signature.stdout.decode()
    date = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    commit = gh(f"{API_ROOT}/repos/{REPO}/git/commits", "POST", json={
        "message": message, "tree": tree, "parents": [parent],
        "author": {"name": name, "email": email, "date": date},
        "committer": {"name": name, "email": email, "date": date},
        "signature": signature,
    }).json()
    # The hash covers the signature, so it matches only if GitHub created the
    # commit that was signed
    gpgsig = "gpgsig " + signature.rstrip("\n").replace("\n", "\n ") + "\n"
    signed = f"{headers}{gpgsig}\n{message}".encode()
    expected = hashlib.sha1(f"commit {len(signed)}\0".encode() + signed).hexdigest()
    if commit["sha"] != expected:
        raise SystemExit(f"❌ GitHub created commit {commit['sha']}, rather than the signed commit {expected}")
    verification = commit.get("verification") or {}
    if not verification.get("verified"):
        print(f"⚠️  GitHub doesn't show commit {commit['sha']} as verified ({verification.get('reason')}): "
              f"add gpg key {key} to your GitHub account, if it isn't there")
    return commit["sha"]

def open_bump_pr(version, changes, base_sha):
    branch = f"tceng-tc-v{version}"
    pr = find_pr(branch)
    if pr and pr["state"] == "closed" and not pr["merged_at"]:
        raise SystemExit(f"❌ {pr['html_url']} was closed without merging; reopen it or delete branch {branch}.")
    if pr:
        print(f"♻️  Reusing {pr['html_url']}")
        enable_auto_merge(pr)
        return pr

    title = f"chore(tceng): bump to TC v{version}"
    base_tree = gh(f"{API_ROOT}/repos/{REPO}/git/commits/{base_sha}").json()["tree"]["sha"]
    tree = gh(f"{API_ROOT}/repos/{REPO}/git/trees", "POST", json={
        "base_tree": base_tree,
        "tree": [{"path": p, "mode": "100644", "type": "blob", "content": c} for p, c in changes.items()],
    }).json()["sha"]
    commit = create_signed_commit(title, tree, base_sha)
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
    enable_auto_merge(pr)
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

def bump_taskcluster_version(wait=True):
    """Make every TCEng config on worker-images' main pin the latest Taskcluster
    release, via a PR that must be merged before continuing. With wait=False,
    just open (or reuse) the PR and return without waiting for it to be merged."""
    version = latest_taskcluster_version()
    base_sha = gh(f"{API_ROOT}/repos/{REPO}/git/ref/heads/{REF}").json()["object"]["sha"]
    changes = outdated_tceng_configs(base_sha, version)
    if not changes:
        print(f"✅ {REPO} {TCENG_CONFIG_DIR} already pins Taskcluster v{version}")
        return
    print(f"⬆️  Bumping to Taskcluster v{version}: {', '.join(sorted(changes))}")
    pr = open_bump_pr(version, changes, base_sha)
    if not wait:
        print(f"⏸️  {pr['html_url']} needs to be merged before images can be built.")
        return
    wait_for_merge(pr)
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
                timed_out = conclusion == "cancelled" and hit_time_limit(run_id)
                if (conclusion in RERUN_CONCLUSIONS or timed_out) and run["run_attempt"] < MAX_RUN_ATTEMPTS:
                    reason = " (time limit exceeded)" if timed_out else ""
                    print(f"   🔁 {cfg} ({workflow_file}): run #{run_number} attempt {run['run_attempt']} "
                          f"finished with conclusion={conclusion}{reason}; rerunning failed jobs")
                    gh(f"{API_ROOT}/repos/{REPO}/actions/runs/{run_id}/rerun-failed-jobs", method="POST")
                    min_attempt[run_id] = run["run_attempt"] + 1
                    continue
                results[(workflow_file, cfg)] = (run_id, run_number, conclusion, workflow_file)
                icon = "✅" if conclusion == "success" else "❌"
                print(f"   {icon} {cfg} ({workflow_file}): run #{run_number} finished with conclusion={conclusion}")
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

def bootstrap_script_url(image_set, cloud_provider, sha):
    """URL of the bootstrap script that worker-images (at commit `sha`) ran to
    build `image_set` for `cloud_provider`, or None if it can't be determined."""
    url = f"{API_ROOT}/repos/{REPO}/contents/{TCENG_CONFIG_DIR}/{image_set}.yaml"
    try:
        config = YAML(typ="safe").load(base64.b64decode(gh(url, params={"ref": sha}).json()["content"]))
        # See packer/tceng-{azure,gcp,aws}.pkr.hcl in worker-images
        if cloud_provider == "azure":
            path = f"scripts/windows/tceng/{config['vm']['bootstrapscript']}.ps1"
        else:
            path = f"scripts/linux/tceng/{config['vm']['script_name']}"
    except (requests.exceptions.HTTPError, KeyError, TypeError) as e:
        print(f"      ⚠️ Couldn't determine bootstrap script of {image_set} ({cloud_provider}) at {sha}: {e!r}")
        return None
    return f"https://raw.githubusercontent.com/{REPO}/{sha}/{path}"

def update_bootstrap_script(data, image_set, script_url):
    """Link to the bootstrap script in the worker type metadata of
    `image_set`, so that users can see how its images were built."""
    if data[image_set].get("workerImplementation") != "generic-worker":
        return
    config = data[image_set].setdefault("workerConfig", {}).setdefault("genericWorker", {}).setdefault("config", {})
    machine_setup = config.setdefault("workerTypeMetadata", {}).setdefault("machine-setup", {})
    machine_setup["script"] = script_url
    print(f"      ✅ Set {image_set} workerTypeMetadata.machine-setup.script = {script_url}")

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


# ---- Logging / fxci ----
FXCI_REPO = "mozilla-releng/fxci-config"
FXCI_IMAGES_FILE = "worker-images.yml"
# fxci's worker pools use some of the same image sets, under other names:
# fxci image -> (image set, fxci provider id). Those that fxci doesn't have
# (yet) are skipped.
FXCI_IMAGES = {
    "gw-ubuntu-24-04": ("generic-worker-ubuntu-24-04", "fxci-level1-gcp"),
    "gw-ubuntu-24-04-arm64": ("generic-worker-ubuntu-24-04-arm64", "fxci-level1-gcp"),
    "gw-win2022": ("generic-worker-win2022", "azure2"),
    "gw-win2022-gpu": ("generic-worker-win2022-gpu", "azure2"),
    "gw-ubuntu-24-04-staging": ("generic-worker-ubuntu-24-04-staging", "fxci-level1-gcp"),
    "gw-ubuntu-24-04-arm64-staging": ("generic-worker-ubuntu-24-04-arm64-staging", "fxci-level1-gcp"),
    "gw-win2022-staging": ("generic-worker-win2022-staging", "azure2"),
    "gw-win2022-gpu-staging": ("generic-worker-win2022-gpu-staging", "azure2"),
}
# Keys of an fxci Azure image that aren't locations
FXCI_AZURE_SETTINGS = {"version", "resource_group", "sbom", "name"}
# Merged by fxci into the workerTypeMetadata of the worker pools using an image
FXCI_METADATA_KEY = "worker-type-metadata"
WORKER_IMAGES_RAW_URL = f"https://raw.githubusercontent.com/{REPO}/"

def log_images():
    """Print the images of the image sets that worker-images builds for us."""
    with open(IMAGESETS_FILE) as f:
        data = yaml.load(f)
    print(f"\n🖼️  Images in config/imagesets.yml of the image sets built by {REPO}, "
          "with the GitHub Actions jobs that built them:")
    for image_set in sorted({cfg for cfgs in WORKFLOWS.values() for cfg in cfgs}):
        print(f"   {image_set}:")
        for cloud, key in (("gcp", "image"), ("aws", "amis"), ("azure", "images")):
            images = data.get(image_set, {}).get(cloud, {}).get(key)
            if not images:
                continue
            regions = {cloud: images} if isinstance(images, str) else {f"{cloud} {r}": i for r, i in images.items()}
            names = {region: image.rsplit("/", 1)[-1] for region, image in regions.items()}
            jobs, _ = worker_images_jobs(image_set, cloud, list(names.values()))
            for region, name in names.items():
                print(f"      {region}: {name} ({jobs.get(name, 'job not found')})")

def update_fxci_script(imagesets, image_set, worker_images, fxci_image):
    """Link fxci's `fxci_image` to the worker-images bootstrap script that the
    images of `image_set` were built with, in place (fxci merges it into the
    worker type metadata of its worker pools, as community-tc does). Returns
    the script's URL, or None if `image_set` doesn't link to a worker-images
    script, e.g. because its images haven't been rebuilt since it last linked
    to a script in this repository."""
    gw_config = imagesets[image_set].get("workerConfig", {}).get("genericWorker", {}).get("config", {})
    script = gw_config.get("workerTypeMetadata", {}).get("machine-setup", {}).get("script", "")
    if not script.startswith(WORKER_IMAGES_RAW_URL):
        print(f"ℹ️  {image_set} doesn't link to a {REPO} bootstrap script, so not linking fxci's {fxci_image} to one")
        return None
    image = worker_images[fxci_image]
    if FXCI_METADATA_KEY not in image:
        # First, since the blank line after an image belongs to its last key
        image.insert(0, FXCI_METADATA_KEY, {})
    image[FXCI_METADATA_KEY].setdefault("machine-setup", {})["script"] = script
    return script

def update_fxci_images(imagesets, worker_images):
    """Point the images in `worker_images` (fxci's worker-images.yml) at those in
    `imagesets`, in place, and link the updated ones to the bootstrap scripts
    they were built with. Returns ([(fxci image, location, old, new)],
    {fxci image: bootstrap script URL})."""
    changes = []
    scripts = {}
    missing = []
    for fxci_image, (image_set, provider_id) in FXCI_IMAGES.items():
        if provider_id not in worker_images.get(fxci_image, {}):
            print(f"ℹ️  fxci has no {fxci_image} image for {provider_id}, so not updating it")
            continue
        current = worker_images[fxci_image][provider_id]
        changed = len(changes)
        if isinstance(current, str):
            # GCP: one image for all regions
            new = imagesets[image_set]["gcp"]["image"]
            if current != new:
                worker_images[fxci_image][provider_id] = new
                changes.append((fxci_image, None, current, new))
                scripts[fxci_image] = update_fxci_script(imagesets, image_set, worker_images, fxci_image)
            continue
        # Azure: a managed image per location, built in fxci's subscription by
        # worker-images, which fxci references by name
        if current.get("version") != "NA":
            raise SystemExit(f"❌ fxci's {fxci_image} doesn't reference managed images, so can't be updated")
        if "deployment_id" in current:
            raise SystemExit(f"❌ fxci's {fxci_image} has a deployment_id, which fxci appends to managed image "
                             "names, so can't be updated with full image names")
        built = imagesets[image_set]["azure"]["images"]
        for location in [k for k in current if k not in FXCI_AZURE_SETTINGS]:
            path = built.get(location.replace("-", ""))
            if not path:
                missing.append(f"{fxci_image} ({image_set}) {location}")
                continue
            new = path.rsplit("/", 1)[-1]
            if current[location] != new:
                changes.append((fxci_image, location, current[location], new))
                current[location] = new
        if len(changes) > changed:
            scripts[fxci_image] = update_fxci_script(imagesets, image_set, worker_images, fxci_image)
    if missing:
        raise SystemExit("❌ fxci uses these locations, but there are no new images for them (did their builds fail?), "
                         "so not opening an fxci PR:\n" + "\n".join(f"   - {m}" for m in missing))
    return changes, {image: script for image, script in scripts.items() if script}

def worker_images_jobs(image_set, cloud, image_names):
    """({image name: URL of the worker-images GitHub Actions job that built it},
    run) for the latest successful run that built `image_set` for `cloud` and
    all of `image_names` (as shown by its job logs), or ({}, None) if there
    isn't one."""
    workflow_file = next(wf for wf, cfgs in TARGET_WORKFLOWS["all"].items()
                         if get_cloud_provider(wf) == cloud and image_set in cfgs)
    checked = set()
    # GitHub's list of runs occasionally misses recent ones, so list them again
    # if none of the listed runs built the images
    for attempt in range(3):
        if attempt:
            time.sleep(10)
        runs = [run for run in list_dispatch_runs_for_workflow(workflow_file)
                if title_to_config(run.get("display_title") or run.get("name", "")) == image_set
                and run["conclusion"] == "success"]
        for run in sorted(runs, key=lambda r: r["created_at"], reverse=True)[:5]:
            if run["id"] in checked:
                continue
            checked.add(run["id"])
            logs = {}
            for job in get_workflow_jobs(run["id"]):
                if job["conclusion"] != "success":
                    continue
                try:
                    logs[job["html_url"]] = download_job_log(job["id"])
                except requests.exceptions.HTTPError:
                    pass  # e.g. logs expired
            jobs = {}
            for name in image_names:
                url = next((url for url, log in logs.items() if name in log), None)
                if url:
                    jobs[name] = url
            if len(jobs) == len(set(image_names)):
                return jobs, run
    print(f"⚠️  Couldn't find the {REPO} jobs that built {image_set} ({cloud}) images {', '.join(image_names)}")
    return {}, None

def fxci_pr_text(changes, scripts):
    """Title and body of the fxci PR for `changes` and `scripts` (from
    update_fxci_images)."""
    images = sorted({image for image, *_ in changes})
    jobs = {}
    versions = set()
    for image in images:
        image_set, _ = FXCI_IMAGES[image]
        # GCP images are for all locations (None)
        cloud = "gcp" if any(location is None for i, location, *_ in changes if i == image) else "azure"
        image_jobs, run = worker_images_jobs(image_set, cloud,
                                             [new.rsplit("/", 1)[-1] for i, _, _, new in changes if i == image])
        jobs.update(image_jobs)
        if run:
            # The Taskcluster version that the run's TCEng config pinned
            url = f"{API_ROOT}/repos/{REPO}/contents/{TCENG_CONFIG_DIR}/{image_set}.yaml"
            config = base64.b64decode(gh(url, params={"ref": run["head_sha"]}).json()["content"]).decode("utf-8")
            match = TASKCLUSTER_VERSION_RE.search(config)
            if match:
                versions.add(match.group(3))
    title = "Update TCEng worker images" + (f" to Taskcluster {', '.join(sorted(versions))}" if versions else "")

    def linked(name):
        return f"[`{name}`]({jobs[name]})" if name in jobs else f"`{name}`"

    rows = "\n".join(f"| `{image}` | {location or 'all'} | `{old.rsplit('/', 1)[-1]}` | {linked(new.rsplit('/', 1)[-1])} |"
                     for image, location, old, new in changes)
    body = f"""Use the latest images built by the TCEng workflows in [{REPO}](https://github.com/{REPO}). Each new image links to the GitHub Actions job that built it.

| Image | Location | Old | New |
|---|---|---|---|
{rows}"""
    if scripts:
        body += f"""

Each updated image's `{FXCI_METADATA_KEY}` links to the {REPO} bootstrap script it was built with:

""" + "\n".join(f"* `{image}`: {script}" for image, script in sorted(scripts.items()))
    return title, body

def open_fxci_pr():
    """Open a PR (from the GitHub user's fork) to have fxci use the image sets'
    latest images too, since fxci's config can only be changed with a PR."""
    with open(IMAGESETS_FILE) as f:
        imagesets = yaml.load(f)
    with tempfile.TemporaryDirectory() as tmp:
        def git(*args):
            return subprocess.run(["git", *args], cwd=f"{tmp}/fxci-config", check=True,
                                  capture_output=True, text=True, pass_fds=GPG_PASSPHRASE_FDS).stdout.strip()

        # Clones your fork (creating it if needed) as `origin`, with fxci-config as `upstream`
        fork = subprocess.run(["gh", "repo", "fork", FXCI_REPO, "--clone", "--default-branch-only"], cwd=tmp,
                              capture_output=True, text=True)
        if fork.returncode != 0:
            raise SystemExit(f"❌ Couldn't fork and clone {FXCI_REPO}:\n{fork.stdout}{fork.stderr}")
        git("fetch", "upstream", "main")
        git("checkout", "--detach", "upstream/main")

        fxci_yaml = YAML()
        fxci_yaml.preserve_quotes = True
        fxci_yaml.width = 4096
        images_file = f"{tmp}/fxci-config/{FXCI_IMAGES_FILE}"
        with open(images_file) as f:
            fxci_yaml.explicit_start = f.read().startswith("---")
        with open(images_file) as f:
            worker_images = fxci_yaml.load(f)
        changes, scripts = update_fxci_images(imagesets, worker_images)
        if not changes:
            print(f"✅ {FXCI_REPO} already uses the latest images")
            return
        with open(images_file, "w") as f:
            fxci_yaml.dump(worker_images, f)

        # The same images give the same branch, so a rerun reuses the PR
        with open(images_file, "rb") as f:
            branch = f"tceng-images-{hashlib.sha256(f.read()).hexdigest()[:12]}"
        existing = subprocess.run(["gh", "pr", "list", "--repo", FXCI_REPO, "--head", branch, "--state", "open",
                                   "--json", "url", "--jq", ".[].url"], capture_output=True, text=True, check=True).stdout.strip()
        if existing:
            print(f"♻️  Reusing {existing}")
            return

        title, body = fxci_pr_text(changes, scripts)
        git("commit", "--all", "--message", title)
        git("push", "--force", "origin", f"HEAD:refs/heads/{branch}")
        fork_owner = subprocess.run(["gh", "api", "user", "--jq", ".login"], capture_output=True, text=True, check=True).stdout.strip()
        subprocess.run(["gh", "pr", "create", "--repo", FXCI_REPO, "--base", "main", "--head", f"{fork_owner}:{branch}",
                        "--title", title, "--body", body], check=True)


# ---- Main ----
def main():
    # Opening the PR early gives someone time to review and merge it while the
    # rest of the deployment runs; a later run without this flag waits for it.
    if sys.argv[1:] == ["--open-bump-pr"]:
        bump_taskcluster_version(wait=False)
        return
    if sys.argv[1:] == ["--log-images"]:
        log_images()
        return
    if sys.argv[1:] == ["--open-fxci-pr"]:
        open_fxci_pr()
        return

    if RUNS_FILE and os.path.exists(RUNS_FILE):
        with open(RUNS_FILE) as f:
            run_map = {(wf, cfg): (run_id, run_number, wf) for wf, cfg, run_id, run_number in json.load(f)}
        print(f"♻️  Resuming the {len(run_map)} run(s) in {RUNS_FILE}")
    else:
        # 0) Builds use worker-images' main, so it must pin the latest Taskcluster first
        if os.environ.get("UPDATE_TASKCLUSTER_VERSION", "true") == "true":
            bump_taskcluster_version()

        # Only match runs triggered from here on, not any started while waiting for the PR.
        global SCRIPT_START_TIME
        SCRIPT_START_TIME = datetime.now(timezone.utc)

        # 1) Trigger all workflows in parallel and wait for all to complete
        run_map = trigger_all_workflows(WORKFLOWS)
        if RUNS_FILE and run_map:
            with open(RUNS_FILE, "w") as f:
                json.dump([[wf, cfg, run_id, run_number] for (wf, cfg), (run_id, run_number, _) in run_map.items()], f)

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
    staged_shas = {}  # (image_set, cloud_provider) -> worker-images commit the images were built from
    updated = False
    failed_jobs = []

    # all_results: (workflow_file, config) -> (run_id, run_number, conclusion, workflow_file)
    for (workflow_file, cfg), (run_id, run_number, _conclusion, _) in all_results.items():
        cloud_provider = get_cloud_provider(workflow_file)
        print(f"\n🔍 Processing workflow run #{run_number} for {cfg} (run_id={run_id}, cloud={cloud_provider})")
        # Reruns of failed jobs build from the same commit as the original run
        head_sha = get_run_status(run_id)["head_sha"]
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
            staged_shas[key] = head_sha

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

    script_urls = {}  # image_set -> {bootstrap script URL: [cloud_provider]}
    for (image_set, cloud_provider), region_to_image in staged_updates.items():
        if update_yaml_file_bulk(data, image_set, cloud_provider, region_to_image):
            updated = True
            script_url = bootstrap_script_url(image_set, cloud_provider, staged_shas[(image_set, cloud_provider)])
            if script_url:
                script_urls.setdefault(image_set, {}).setdefault(script_url, []).append(cloud_provider)

    for image_set, urls in script_urls.items():
        # An image set's builds for different clouds (e.g. AWS and GCP) could
        # run from different commits, if worker-images changed in between
        if len(urls) > 1:
            print(f"      ⚠️ {image_set} images were built with different bootstrap scripts: "
                  + ", ".join(f"{url} ({'/'.join(clouds)})" for url, clouds in urls.items()))
        update_bootstrap_script(data, image_set, list(urls)[-1])

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
