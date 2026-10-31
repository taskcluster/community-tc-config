#!/usr/bin/env python3
"""Checks, before imageset.sh changes anything, that you have the access that
the run needs (run by run.sh, in its container, under with-gpg):

  preflight.py accounts   After signing in: GitHub, Google Cloud, Azure, AWS
  preflight.py secrets    After cloning the password store: its entries, and
                          the Taskcluster credentials

Each check only reads. If any fails, it says what is missing, and how to get
it, and exits non-zero, so that the run stops before it starts. Checks of
things that wouldn't stop the run (e.g. commits showing as verified on
GitHub) only warn.

The settings (BUILD_IMAGES etc.) decide which checks apply, as in run.sh.
"""

import fnmatch
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse

# How to get each kind of access, as found in mozilla/global-platform-admin,
# the cloud projects' IAM policies, the password store's .gpg-id, past
# Bugzilla requests, and deployment-details.md.
HOW = {
    # Its members are all maintainers, who can add you
    "community-tc-admin": "ask a member of the taskcluster/community-tc-admins GitHub team "
                          "(https://github.com/orgs/taskcluster/teams/community-tc-admins/members), e.g. in "
                          "#taskcluster:mozilla.org on Matrix (https://chat.mozilla.org), to add you to it",
    # Membership is managed in mozilla/global-platform-admin (github/tf/mozilla-corporation/organization_teams.tf),
    # and single sign-on to the organization needs the ghe_<org>_users access group
    "github-org": "request the ghe_{org}_users access group at https://people.mozilla.org, and open a pull request "
                  "that adds your Mozilla email to organization_members[\"{org}\"] in "
                  "github/tf/mozilla-corporation/organization_teams.tf of https://github.com/mozilla/global-platform-admin "
                  "(your people.mozilla.org profile needs your GitHub username, and you need to be in the "
                  "gh_access_mozilla LDAP group, which you request in a bug in Infrastructure & Operations :: "
                  "Infrastructure: LDAP, at https://bugzilla.mozilla.org)",
    # The tceng team (Taskcluster Engineering) has the TCEng configs (CODEOWNERS); its maintainer is in relops
    "worker-images": "ask a maintainer of the mozilla-platform-ops/tceng GitHub team "
                     "(https://github.com/orgs/mozilla-platform-ops/teams/tceng/members) to add you to it, for "
                     "write access to mozilla-platform-ops/worker-images",
    # The owners of the projects (gcloud projects get-iam-policy) are in the Taskcluster team
    "gcp": "ask an owner of the {project} Google Cloud project (in the Taskcluster team) for the Compute Viewer role "
           "on it (roles/compute.viewer)",
    "gcp-passwords": "ask an owner of the {project} Google Cloud project (in the Taskcluster team) for the Source "
                     "Repository Reader role on it (roles/source.reader)",
    # The Taskcluster group (in Microsoft Entra, managed by relops) is Contributor on our subscription, and
    # Reader on the FXCI one, where worker-images builds some images
    "azure": "ask Release Operations (relops), who manage it, to add you to the Taskcluster group in Mozilla's "
             "Microsoft Entra (Azure) tenant, which has access to the Azure subscription {subscription}",
    "azure-other": "ask Release Operations (relops), who manage it, to add you to the Taskcluster group in Mozilla's "
                   "Microsoft Entra (Azure) tenant, which can read the images in the Azure subscription(s) {names}",
    # From mozilla/global-platform-admin's aws/tf/sso/cloudservices/main.tf
    "aws": "request membership of the cloudservices_aws_taskcluster_devs access group at "
           "https://people.mozilla.org (which gives the AdministratorAccess role on the AWS account "
           "moz-fx-tc-community-workers, 885316786408, in Mozilla's AWS SSO), or else in a bug in Infrastructure & "
           "Operations :: SSO: Requests, at https://bugzilla.mozilla.org",
    # Anyone whose key is in its .gpg-id can
    "password-store": "ask someone whose gpg key the password store is encrypted to (in the Taskcluster team) to add "
                      "yours ({key}) to its .gpg-id, and re-encrypt it (pass init)",
    # The root credentials are in the deployment's configuration (deployment-details.md)
    "taskcluster": "ask the Taskcluster team: community-tc/root in the password store may be out of date, or the "
                   "deployment's root credentials may have changed (which cloudops manage: see Cloud Services :: "
                   "Operations: Taskcluster Services, at https://bugzilla.mozilla.org)",
}

BUILD_IMAGES = os.environ["BUILD_IMAGES"] == "true"
DEPLOY_IMAGES = os.environ["DEPLOY_IMAGES"] == "true"
UPDATE_OFFERINGS = os.environ["UPDATE_OFFERINGS"] == "true"
UPDATE_TASKCLUSTER_VERSION = os.environ["UPDATE_TASKCLUSTER_VERSION"] == "true"
UPDATE_FXCI_IMAGES = os.environ["UPDATE_FXCI_IMAGES"] == "true"
# Space-separated, from run.sh: the macOS workers still to update, and whether
# AWS is needed (the offerings step may be done already)
PENDING_MACS = os.environ.get("IMAGESET_PENDING_MACS", "").split()
NEEDS_AWS = os.environ.get("IMAGESET_NEEDS_AWS") == "true"
# tc-admin apply reads community-tc/secret-values.yml too
TC_ADMIN = UPDATE_OFFERINGS or DEPLOY_IMAGES

COMMUNITY_TC_CONFIG = "taskcluster/community-tc-config"
WORKER_IMAGES = "mozilla-platform-ops/worker-images"
FXCI_CONFIG = "mozilla-releng/fxci-config"
GCP_PROJECT = os.environ.get("GCP_PROJECT", "taskcluster-imaging")
AZURE_SUBSCRIPTION_ID = os.environ.get("AZURE_SUBSCRIPTION_ID", "")
AZURE_RESOURCE_GROUP = os.environ.get("AZURE_IMAGE_RESOURCE_GROUP", "rg-tc-eng-images")
# The file descriptor that with-gpg gives the passphrase on, if it's open
def _open_fds(fd):
    try:
        os.fstat(fd)
        return (fd,)
    except OSError:
        return ()
GPG_FDS = _open_fds(int(os.environ["IMAGESET_GPG_PASSPHRASE_FD"])) if os.environ.get("IMAGESET_GPG_PASSPHRASE_FD") else ()

# Errors of a command that may well not happen again if it is repeated (e.g. a
# dropped connection)
TRANSIENT_RE = re.compile(
    r"SSL|EOF|Connection (aborted|reset|refused|timed out|closed)|RemoteDisconnected|timed out|Timeout|"
    r"Could not resolve|Name or service not known|Temporary failure in name resolution|Max retries exceeded|"
    r"TooManyRequests|Throttl|InternalServerError|ServiceUnavailable|GatewayTimeout|BadGateway|"
    r"HTTP 5\d\d|error: 5\d\d|remote end hung up|RPC failed|i/o timeout|TLS handshake|No route to host|"
    r"Network is unreachable", re.I)
# Up to about 6 minutes
RETRY_SECONDS = [5, 10, 20, 40, 60, 60, 60, 60, 60]

failures = []
warnings = []
passed = 0


def ok():
    global passed
    passed += 1


def fail(what, how):
    failures.append((what, how))


def warn(what, how=""):
    warnings.append((what, how))


def run(*args, **kwargs):
    """Runs a command (each check only reads), repeating it on transient
    errors, so that they aren't mistaken for missing access"""
    for wait in [*RETRY_SECONDS, None]:
        r = subprocess.run(args, capture_output=True, text=True, **kwargs)
        if r.returncode == 0 or wait is None or not TRANSIENT_RE.search(r.stderr + r.stdout[:2000]):
            return r
        time.sleep(wait)


# ---- GitHub ----

def gh(path, method="GET"):
    """(status, headers, body) of a GitHub API request"""
    r = run("gh", "api", "--include", "--method", method, path)
    head, _, body = r.stdout.partition("\r\n\r\n") if "\r\n\r\n" in r.stdout else r.stdout.partition("\n\n")
    lines = head.splitlines()
    status = int(lines[0].split()[1]) if lines and lines[0].startswith("HTTP") else 0
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    try:
        body = json.loads(body) if body.strip() else None
    except json.JSONDecodeError:
        pass
    return status, headers, body


def graphql(query):
    r = run("gh", "api", "graphql", "-f", f"query={query}")
    return json.loads(r.stdout) if r.stdout.strip() else {}


def sso_url(headers):
    m = re.search(r"url=(\S+)", headers.get("x-github-sso", ""))
    return m.group(1) if m else None


def check_org(org):
    """You're an active member of the org, and your sign-in is authorized for
    its single sign-on. If it isn't, has you authorize it, and checks again."""
    for _ in range(3):
        status, headers, body = gh(f"user/memberships/orgs/{org}")
        url = sso_url(headers)
        if status == 403 and url:
            print(f"Your GitHub sign-in isn't authorized for the {org} organization's single sign-on.")
            subprocess.run([os.environ["BROWSER"], url])
            input("Once you have authorized it there, press Enter to check again: ")
            continue
        if status == 200 and body.get("state") == "active":
            ok()
            return True
        if status == 200:
            fail(f"GitHub: your membership of the {org} organization is {body.get('state')}",
                 f"accept the invitation at https://github.com/orgs/{org}/invitation")
        else:
            fail(f"GitHub: you aren't a member of the {org} organization", HOW["github-org"].format(org=org))
        return False
    fail(f"GitHub: your sign-in still isn't authorized for the {org} organization's single sign-on",
         f"authorize it at https://github.com/orgs/{org}/sso, then rerun")
    return False


def check_push_to_main():
    """How run.sh publishes commits to community-tc-config (in the access
    file): pushing them to main, which its protection only allows admins to,
    or else in a pull request, from a branch (with write access), or from your
    fork"""
    owner, name = COMMUNITY_TC_CONFIG.split("/")
    data = graphql(f'{{ repository(owner: "{owner}", name: "{name}") {{ viewerPermission '
                   f'ref(qualifiedName: "refs/heads/main") {{ refUpdateRule {{ viewerCanPush }} }} }} }}')
    repo = (data.get("data") or {}).get("repository") or {}
    rule = (repo.get("ref") or {}).get("refUpdateRule")
    writer = repo.get("viewerPermission") in ("WRITE", "MAINTAIN", "ADMIN")
    if (rule["viewerCanPush"] if rule else writer):
        publish("main")
        ok()
        return
    if writer:
        publish("branch")
    elif check_fork(COMMUNITY_TC_CONFIG):
        publish("fork")
    else:
        return
    ok()
    warn(f"GitHub: you can't push to main of {COMMUNITY_TC_CONFIG} (only its admins can), so its changes will be in "
         f"pull requests, which the run waits for someone to approve and merge", f"to push them directly, "
         + HOW["community-tc-admin"])


def publish(how):
    with open(os.environ["IMAGESET_ACCESS_FILE"], "a") as f:
        f.write(f"COMMUNITY_TC_CONFIG_PUBLISH={how}\n")


def check_worker_images():
    status, _, repo = gh(f"repos/{WORKER_IMAGES}")
    if status != 200 or not (repo.get("permissions") or {}).get("push"):
        fail(f"GitHub: you can't write to {WORKER_IMAGES} (to trigger its workflows, rerun failed jobs, and open "
             f"the Taskcluster version pull request)", HOW["worker-images"])
        return
    ok()
    for workflow in workflows():
        status, _, body = gh(f"repos/{WORKER_IMAGES}/actions/workflows/{workflow}")
        if status == 200 and body.get("state") == "active":
            ok()
        else:
            fail(f"GitHub: workflow {workflow} of {WORKER_IMAGES} isn't active ({status}: "
                 f"{(body or {}).get('state') or (body or {}).get('message')})",
                 "ask Release Operations (relops), who own the repository (see its CODEOWNERS)")
    if UPDATE_TASKCLUSTER_VERSION:
        status, _, rules = gh(f"repos/{WORKER_IMAGES}/rules/branches/tceng-tc-v0.0.0")
        if status == 200 and rules:
            warn(f"GitHub: rules of {WORKER_IMAGES} apply to its tceng-tc-v* branches, which may stop imageset.sh "
                 f"creating the Taskcluster version pull request's branch: {[r.get('type') for r in rules]}")


def workflows():
    """The worker-images workflows of this target, from rel-sre-imagesets.py"""
    spec = importlib.util.spec_from_file_location("rel_sre_imagesets", "/work/imagesets/rel-sre-imagesets.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return sorted(module.WORKFLOWS)


def check_fork(upstream):
    """That a pull request can come from your fork of upstream (which may not
    exist yet)"""
    status, _, repo = gh(f"repos/{upstream}")
    if status != 200 or not repo.get("allow_forking"):
        fail(f"GitHub: {upstream} can't be forked, for its pull request", "ask its admins")
        return False
    login = gh("user")[2]["login"]
    name = upstream.split("/")[1]
    status, _, fork = gh(f"repos/{login}/{name}")
    if status == 200 and (fork.get("parent") or {}).get("full_name") != upstream:
        fail(f"GitHub: your repository {login}/{name} isn't a fork of {upstream}, so it can't be used for its pull "
             f"request", f"rename or delete it (https://github.com/{login}/{name}/settings)")
        return False
    return True


def check_fxci_fork():
    if check_fork(FXCI_CONFIG):
        ok()


def check_scopes():
    _, headers, _ = gh("user")
    scopes = {s.strip() for s in headers.get("x-oauth-scopes", "").split(",")}
    missing = {"repo", "workflow"} - scopes
    if missing:
        fail(f"GitHub: your sign-in lacks the scopes {', '.join(sorted(missing))}",
             "rerun, and approve them when signing in to GitHub")
    else:
        ok()


def check_verified_commits():
    """That commits will show as verified (otherwise only a warning)"""
    email = os.environ["IMAGESET_GIT_EMAIL"]
    key = os.environ["IMAGESET_GPG_KEY"]
    status, _, emails = gh("user/emails")
    if status == 200 and not email.endswith("@users.noreply.github.com") and \
            not any(e["email"].lower() == email.lower() and e["verified"] for e in emails):
        warn(f"GitHub: {email} isn't a verified email of your GitHub account, so your commits won't be linked to "
             f"it, or show as verified", "add it at https://github.com/settings/emails")
    status, _, keys = gh("user/gpg_keys")
    if status != 200:
        return
    ids = {k[-16:].upper() for k in signing_key_ids(key)}
    uploaded = [k for k in keys if {k.get("key_id", "").upper(), *(s.get("key_id", "").upper() for s in k.get("subkeys", []))} & ids]
    if not uploaded:
        warn(f"GitHub: your gpg key {key} isn't in your GitHub account, so your commits won't show as verified",
             f"add it (gpg --armor --export {key}) at https://github.com/settings/gpg/new")
    elif not any(e["email"].lower() == email.lower() and e.get("verified") for k in uploaded for e in k.get("emails", [])):
        warn(f"GitHub: your gpg key {key} in your GitHub account doesn't have {email} as a verified email, so your "
             f"commits won't show as verified", "add the email to the key, and upload it again")


def signing_key_ids(key):
    """The fingerprints of the key and its subkeys"""
    r = run("gpg", "--with-colons", "--list-keys", key)
    return [line.split(":")[9] for line in r.stdout.splitlines() if line.startswith("fpr:")]


# ---- Google Cloud ----

def check_gcp():
    if UPDATE_OFFERINGS:
        r = run("gcloud", "compute", "machine-types", "list", "--project", GCP_PROJECT, "--zones", "us-central1-a",
                "--limit", "1", "--format", "value(name)")
        if r.returncode == 0:
            ok()
        else:
            fail(f"Google Cloud: you can't list machine types in project {GCP_PROJECT}: {last_line(r.stderr)}",
                 HOW["gcp"].format(project=GCP_PROJECT))


def check_password_store_access():
    url = os.environ["IMAGESET_PASSWORD_STORE_URL"]
    r = run("git", "ls-remote", url)
    if r.returncode == 0:
        ok()
    else:
        project = urllib.parse.urlsplit(url).path.split("/")[2] if "/p/" in url else url
        fail(f"Google Cloud: you can't read the password store ({url}): {last_line(r.stderr)}",
             HOW["gcp-passwords"].format(project=project))


def last_line(text):
    lines = [l for l in text.strip().splitlines() if l.strip()]
    return lines[-1].strip() if lines else "(no message)"


# ---- Azure ----

def az(*args):
    r = run("az", *args, "--output", "json")
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None


def allowed(permissions, action):
    """Whether Azure's permissions (of a scope) allow an action"""
    for p in permissions:
        if any(fnmatch.fnmatch(action.lower(), a.lower()) for a in p.get("actions", [])) and \
                not any(fnmatch.fnmatch(action.lower(), a.lower()) for a in p.get("notActions", [])):
            return True
    return False


def azure_permissions(scope):
    result = az("rest", "--method", "get", "--url",
                f"https://management.azure.com{scope}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01")
    return (result or {}).get("value", [])


def check_azure():
    subscriptions = az("account", "list", "--all") or []
    ours = [s for s in subscriptions if s["id"] == AZURE_SUBSCRIPTION_ID]
    if not ours or ours[0].get("state") != "Enabled":
        fail(f"Azure: you don't have access to the subscription {AZURE_SUBSCRIPTION_ID}",
             HOW["azure"].format(subscription=AZURE_SUBSCRIPTION_ID))
        return
    ok()
    if UPDATE_OFFERINGS:
        if allowed(azure_permissions(f"/subscriptions/{AZURE_SUBSCRIPTION_ID}"), "Microsoft.Compute/skus/read"):
            ok()
        else:
            fail(f"Azure: you can't read VM sizes in the subscription {AZURE_SUBSCRIPTION_ID}",
                 HOW["azure"].format(subscription=AZURE_SUBSCRIPTION_ID))
    if DEPLOY_IMAGES:
        group = f"/subscriptions/{AZURE_SUBSCRIPTION_ID}/resourceGroups/{AZURE_RESOURCE_GROUP}"
        permissions = azure_permissions(group)
        actions = [f"Microsoft.Compute/{kind}/{verb}" for kind in ("galleries", "galleries/images",
                   "galleries/images/versions", "disks", "images") for verb in ("write", "delete")]
        missing = [a for a in actions if not allowed(permissions, a)]
        if missing:
            fail(f"Azure: you can't copy images into the resource group {AZURE_RESOURCE_GROUP} (missing "
                 f"{', '.join(missing)})", HOW["azure"].format(subscription=AZURE_SUBSCRIPTION_ID))
        else:
            ok()
        # copy-azure-images.py looks for images in each subscription of the tenant
        tenant = ours[0]["tenantId"]
        unreadable = [s["name"] for s in subscriptions if s["tenantId"] == tenant and s.get("state") == "Enabled"
                      and az("image", "list", "--subscription", s["id"], "--query", "length(@)") is None]
        if unreadable:
            fail(f"Azure: you can't list images in the subscription(s) {', '.join(unreadable)}, which "
                 f"copy-azure-images.py looks in", HOW["azure-other"].format(names=", ".join(unreadable)))
        else:
            ok()


# ---- AWS ----

def check_aws():
    r = run("aws", "sts", "get-caller-identity", "--query", "Arn", "--output", "text")
    if r.returncode != 0 or "AWSReservedSSO_AdministratorAccess" not in r.stdout:
        fail(f"AWS: you don't have the AdministratorAccess role on the account 885316786408 "
             f"({last_line(r.stderr or r.stdout)})", HOW["aws"])
        return
    r = run("aws", "ec2", "describe-instance-type-offerings", "--region", "us-east-1", "--max-results", "5", "--dry-run")
    if "DryRunOperation" in r.stderr:
        ok()
    else:
        fail(f"AWS: you can't list EC2 instance types: {last_line(r.stderr)}", HOW["aws"])


# ---- Secrets ----

def check_pass(entry):
    r = subprocess.run(["pass", "show", entry], capture_output=True, text=True, pass_fds=GPG_FDS)
    if r.returncode == 0:
        ok()
        return r.stdout
    fail(f"Password store: your gpg key can't decrypt {entry} ({last_line(r.stderr)})",
         HOW["password-store"].format(key=os.environ["IMAGESET_GPG_KEY"]))
    return None


def check_secrets():
    root = check_pass("community-tc/root")
    if TC_ADMIN:
        check_pass("community-tc/secret-values.yml")
    for host in PENDING_MACS:
        check_pass(f"mdc1/generic-worker-ci/{host.split('.')[0]}")
    if root and TC_ADMIN:
        import taskcluster
        token = root.split("\n", 1)[0]
        auth = taskcluster.Auth({"rootUrl": os.environ["TASKCLUSTER_ROOT_URL"],
                                 "credentials": {"clientId": os.environ["TASKCLUSTER_CLIENT_ID"], "accessToken": token}})
        try:
            scopes = auth.currentScopes()["scopes"]
        except taskcluster.exceptions.TaskclusterAuthFailure as e:
            fail(f"Taskcluster: the credentials in community-tc/root are rejected ({e})", HOW["taskcluster"])
        else:
            if "*" in scopes:
                ok()
            else:
                fail("Taskcluster: the credentials in community-tc/root don't have the scope *", HOW["taskcluster"])


def check_accounts():
    if UPDATE_OFFERINGS or BUILD_IMAGES:
        if check_org("taskcluster"):
            check_push_to_main()
    if BUILD_IMAGES:
        if check_org("mozilla-platform-ops"):
            check_worker_images()
        if UPDATE_FXCI_IMAGES:
            check_fxci_fork()
    check_scopes()
    check_verified_commits()
    check_password_store_access()
    check_gcp()
    check_azure()
    if NEEDS_AWS:
        check_aws()


def report():
    for what, how in warnings:
        print(f"WARNING: {what}." + (f"\n  To fix it: {how}." if how else ""))
    if failures:
        print("\nimageset.sh can't run, as you are missing access:")
        for what, how in failures:
            print(f"  - {what}.\n    To get it: {how}.")
        print("Once you have it, rerun imageset.sh (or skip what needs it, e.g. with DEPLOY_MACS=false: see README.md).")
        sys.exit(1)
    print(f"Checked your access: all {passed} checks passed.")


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("accounts", "secrets"):
        sys.exit(f"Usage: {sys.argv[0]} accounts|secrets")
    print("Checking your access...")
    {"accounts": check_accounts, "secrets": check_secrets}[sys.argv[1]]()
    report()


if __name__ == "__main__":
    main()
