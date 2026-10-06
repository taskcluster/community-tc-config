#!/usr/bin/env python3
"""
Copy Azure images referenced by config/imagesets.yml into place, before
tc-admin points worker pools at them.

worker-images builds some TCEng Azure images in another subscription (e.g.
FXCI untrusted), but imagesets.yml references them in ours, where worker-manager
creates the VMs. For each referenced image that doesn't exist, find the one
image of that name, in that region, in another subscription of the same tenant,
and copy it:

  source image -> Compute Gallery version (our subscription and region)
               -> temporary disk -> managed image with the referenced id

A managed image can't be copied across subscriptions directly, and read access
on the source is all that's needed this way. The temporary disk and gallery
version are deleted afterwards; the image's tags record its source.

Galleries: an existing gallery in the target resource group and region with
exactly one matching image definition is reused, otherwise
tc_image_copies_<region> / <ostype>-<generation> is created (x64: managed
images don't record the architecture).

Idempotent: existing images are skipped and a tagged gallery version is reused,
so an interrupted run can be re-run. Exits non-zero if anything is missing
afterwards.
"""
import concurrent.futures
import datetime
import json
import re
import subprocess
import sys
import threading
import time

from ruamel.yaml import YAML

IMAGESETS_FILE = "config/imagesets.yml"
POLL_SECONDS = 60
NAME_RE = re.compile(r"[A-Za-z0-9._-]+")
IMAGE_ID_RE = re.compile(
    r"/subscriptions/([0-9a-f-]{36})/resourceGroups/([^/]+)"
    r"/providers/Microsoft\.Compute/images/([^/]+)", re.I)

_print_lock = threading.Lock()


class CopyError(RuntimeError):
    pass


def log(prefix, message):
    with _print_lock:
        print(f"   [{prefix}] {message}" if prefix else message, flush=True)


def az(*args):
    result = subprocess.run(["az", *args, "--only-show-errors", "-o", "json"],
                            capture_output=True, text=True)
    if result.returncode:
        raise CopyError(f"az {' '.join(args[:3])} failed: {result.stderr.strip()}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def az_or_none(*args):
    """For `show` calls: None when the resource doesn't exist."""
    try:
        return az(*args)
    except CopyError as e:
        if "NotFound" in str(e) or "could not be found" in str(e):
            return None
        raise


# ---- Discovery ----

def referenced_images():
    """[(image_id, region)] for every Azure image in imagesets.yml."""
    data = YAML(typ="safe").load(open(IMAGESETS_FILE))
    refs = []
    for image_set, config in data.items():
        for region, image_id in (((config or {}).get("azure") or {}).get("images") or {}).items():
            m = IMAGE_ID_RE.fullmatch(image_id)
            if not m or not NAME_RE.fullmatch(m.group(3)) or not NAME_RE.fullmatch(region):
                raise CopyError(f"{image_set}.azure.images.{region}: unexpected image id {image_id}")
            refs.append((image_id, region))
    return refs


def image_properties(image):
    os_disk = image["storageProfile"]["osDisk"]
    return {"osType": os_disk["osType"], "hyperVGeneration": image.get("hyperVGeneration") or "V1",
            "osState": os_disk["osState"], "dataDisks": len(image["storageProfile"].get("dataDisks") or [])}


def definition_matches(definition, props):
    features = {f["name"]: f["value"] for f in definition.get("features") or []}
    return (definition["osType"].lower() == props["osType"].lower()
            and (definition.get("hyperVGeneration") or "V1") == props["hyperVGeneration"]
            and definition["osState"] == "Generalized"
            and features.get("SecurityType", "Standard") == "Standard")


def plan_copies():
    missing = []
    for image_id, region in referenced_images():
        sub, rg, name = IMAGE_ID_RE.fullmatch(image_id).groups()
        if not az_or_none("image", "show", "--subscription", sub, "-g", rg, "-n", name):
            missing.append({"id": image_id, "sub": sub, "rg": rg, "name": name, "location": region})
    if not missing:
        return []

    tenant = {a["id"]: a["tenantId"] for a in az("account", "list")}
    images_by_sub = {}
    for c in missing:
        if c["sub"] not in tenant:
            raise CopyError(f"{c['name']}: subscription {c['sub']} isn't visible to az")
        matches = []
        for sub, t in tenant.items():
            if sub == c["sub"] or t != tenant[c["sub"]]:
                continue
            if sub not in images_by_sub:
                images_by_sub[sub] = az("image", "list", "--subscription", sub)
            matches += [i for i in images_by_sub[sub] if i["name"] == c["name"]]
        in_region = [i for i in matches if i["location"] == c["location"]]
        if len(in_region) != 1:
            raise CopyError(f"{c['name']}: expected exactly one source image in {c['location']} in another "
                            f"subscription, found {len(in_region)} ({len(matches)} with that name anywhere)")
        c["source"] = in_region[0]
        c["props"] = image_properties(c["source"])
        if c["props"]["osState"] != "Generalized" or c["props"]["dataDisks"]:
            raise CopyError(f"{c['name']}: only generalized, OS-disk-only images are supported ({c['props']})")

    # A gallery image definition per image: reuse a matching one, else plan our own.
    galleries = {}
    next_patch = {}
    today = datetime.date.today().strftime("%Y%m%d")
    for c in missing:
        key = (c["sub"], c["rg"])
        if key not in galleries:
            galleries[key] = az("sig", "list", "--subscription", c["sub"], "-g", c["rg"])
        candidates = [(g["name"], d["name"])
                      for g in galleries[key] if g["location"] == c["location"]
                      for d in az("sig", "image-definition", "list", "--subscription", c["sub"],
                                  "-g", c["rg"], "-r", g["name"])
                      if definition_matches(d, c["props"])]
        own = (f"tc_image_copies_{c['location']}",
               f"{c['props']['osType'].lower()}-{c['props']['hyperVGeneration'].lower()}")
        if own in candidates or not candidates:
            (c["gallery"], c["definition"]), c["create_definition"] = own, own not in candidates
        elif len(candidates) == 1:
            (c["gallery"], c["definition"]), c["create_definition"] = candidates[0], False
        else:
            raise CopyError(f"{c['name']}: {len(candidates)} matching gallery definitions in "
                            f"{c['location']}, expected at most one: {candidates}")

        versions = [] if c["create_definition"] else az(
            "sig", "image-version", "list", "--subscription", c["sub"], "-g", c["rg"],
            "-r", c["gallery"], "-i", c["definition"])
        tagged = [v for v in versions if (v.get("tags") or {}).get("copied_from") == c["name"]]
        if len(tagged) > 1:
            raise CopyError(f"{c['name']}: {len(tagged)} gallery versions tagged copied_from, expected at most one")
        if tagged:
            c["version"] = tagged[0]["name"]
        else:
            dkey = (c["sub"], c["rg"], c["gallery"], c["definition"])
            if dkey not in next_patch:
                used = [int(v["name"].split(".")[2]) for v in versions if v["name"].startswith(f"1.{today}.")]
                next_patch[dkey] = max(used, default=0) + 1
            c["version"] = f"1.{today}.{next_patch[dkey]}"
            next_patch[dkey] += 1
    return missing


# ---- Copying ----

def ensure_definition(c, lock):
    with lock:
        if not az_or_none("sig", "show", "--subscription", c["sub"], "-g", c["rg"], "-r", c["gallery"]):
            log(c["name"], f"creating gallery {c['gallery']}")
            az("sig", "create", "--subscription", c["sub"], "-g", c["rg"], "-r", c["gallery"],
               "--location", c["location"])
        if not az_or_none("sig", "image-definition", "show", "--subscription", c["sub"], "-g", c["rg"],
                          "-r", c["gallery"], "-i", c["definition"]):
            log(c["name"], f"creating image definition {c['definition']}")
            az("sig", "image-definition", "create", "--subscription", c["sub"], "-g", c["rg"],
               "-r", c["gallery"], "-i", c["definition"], "--location", c["location"],
               "--os-type", c["props"]["osType"], "--os-state", "Generalized",
               "--hyper-v-generation", c["props"]["hyperVGeneration"],
               "--publisher", "taskcluster", "--offer", "image-copies", "--sku", c["definition"],
               "--architecture", "x64")


def copy_one(c, gallery_lock):
    name = c["name"]
    common = ["--subscription", c["sub"], "-g", c["rg"]]
    sig = [*common, "-r", c["gallery"], "-i", c["definition"], "-e", c["version"]]

    ensure_definition(c, gallery_lock)
    if not az_or_none("sig", "image-version", "show", *sig):
        log(name, f"creating gallery version {c['gallery']}/{c['definition']}/{c['version']}")
        az("sig", "image-version", "create", *sig, "--managed-image", c["source"]["id"],
           "--location", c["location"], "--target-regions", f"{c['location']}=1=standard_lrs",
           "--exclude-from-latest", "true", "--tags", f"copied_from={name}", "--no-wait")

    started = time.monotonic()
    while True:
        v = az("sig", "image-version", "show", *sig, "--expand", "ReplicationStatus")
        if v["provisioningState"] == "Succeeded":
            break
        if v["provisioningState"] not in ("Creating", "Updating"):
            raise CopyError(f"gallery version is {v['provisioningState']}: {json.dumps(v.get('replicationStatus'))}")
        progress = (((v.get("replicationStatus") or {}).get("summary") or [{}])[0]).get("progress", "?")
        log(name, f"replicating {progress}% ({int(time.monotonic() - started) // 60} min)")
        time.sleep(POLL_SECONDS)

    disk = f"imgcopy-{name}"[:80]
    if not az_or_none("disk", "show", *common, "-n", disk):
        log(name, "creating temporary disk")
        az("disk", "create", *common, "-n", disk, "--location", c["location"],
           "--gallery-image-reference", v["id"], "--sku", "Standard_LRS",
           "--hyper-v-generation", c["props"]["hyperVGeneration"], "--tags", f"temporary_for={name}")
    disk_id = az("disk", "show", *common, "-n", disk)["id"]

    log(name, "creating image")
    az("image", "create", *common, "-n", name, "--location", c["location"], "--source", disk_id,
       "--os-type", c["props"]["osType"], "--hyper-v-generation", c["props"]["hyperVGeneration"],
       "--tags", f"copied_from={c['source']['id']}")
    image = az("image", "show", *common, "-n", name)
    if image["provisioningState"] != "Succeeded" or image["id"].lower() != c["id"].lower():
        raise CopyError(f"image not as expected: state={image['provisioningState']} id={image['id']}")

    az("disk", "delete", *common, "-n", disk, "--yes")
    az("sig", "image-version", "delete", *sig)
    log(name, "done")


def main():
    try:
        copies = plan_copies()
    except CopyError as e:
        sys.exit(f"❌ {e}")
    if not copies:
        print(f"✅ Every Azure image in {IMAGESETS_FILE} exists")
        return

    print(f"📦 Copying {len(copies)} Azure image(s) into place:")
    for c in copies:
        print(f"   {c['source']['id']}\n     -> {c['id']}")
    print("   If this fails, re-run it: done steps are skipped. Check for leftover imgcopy-* disks.", flush=True)

    # One lock per gallery: only copies sharing a gallery wait for its creation.
    locks = {(c["sub"], c["rg"], c["gallery"]): threading.Lock() for c in copies}
    failures = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(copies)) as pool:
        futures = {pool.submit(copy_one, c, locks[(c["sub"], c["rg"], c["gallery"])]): c["name"] for c in copies}
        for f in concurrent.futures.as_completed(futures):
            try:
                f.result()
            except Exception as e:
                failures[futures[f]] = e
                log(futures[f], f"FAILED: {e}")
    if failures:
        sys.exit(f"❌ {len(failures)}/{len(copies)} image copies failed: {', '.join(sorted(failures))}")
    print(f"✅ Copied {len(copies)} Azure image(s)")


if __name__ == "__main__":
    main()
