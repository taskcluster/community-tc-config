# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

from tcadmin.resources import WorkerPool

TYPES = {}

GCP_PROVIDER = 'community-tc-workers-google'
DEFAUlT_GCP_DOCKER_WORKER_IMAGE = "projects/taskcluster-imaging/global/images/docker-worker-gcp-googlecompute-2019-10-08t02-31-36z"

GOOGLE_REGIONS_ZONES = {
    "us-east1": ["b", "c", "d"],
    "us-east4": ["a", "b", "c"],
}

GOOGLE_ZONES_REGIONS = [
    ("{}-{}".format(region, zone), region)
    for region, zones in sorted(GOOGLE_REGIONS_ZONES.items())
    for zone in zones]


def worker_pool_type(fn):
    TYPES[fn.__name__] = fn
    return fn


def build_worker_pool(workerPoolId, cfg):
    wp = TYPES[cfg['type']](**cfg)
    return WorkerPool(
        workerPoolId=workerPoolId,
        description=cfg.get('description', ''),
        owner=cfg.get('owner', 'nobody@mozilla.com'),
        emailOnError=cfg.get('emailOnError', False),
        **wp)


def base_google_config(**cfg):
    return {
        'providerId': GCP_PROVIDER,
        'config': {
            "maxCapacity": 20,
            "minCapacity": 1,
            "launchConfigs": [
                {
                    "capacityPerInstance": 1,
                    "machineType": "zones/{}/machineTypes/n1-standard-4".format(zone),
                    "region": region,
                    "zone": zone,
                    "scheduling": {
                        "onHostMaintenance": "terminate",
                    },
                    "disks": [{
                        "type": "PERSISTENT",
                        "boot": True,
                        "autoDelete": True,
                        # "initializeParams": ..
                    }],
                    "networkInterfaces": [{
                        "accessConfigs": [{
                            "type": "ONE_TO_ONE_NAT"
                        }],
                    }],
                }
                for zone, region in GOOGLE_ZONES_REGIONS
            ]
        },
    }


@worker_pool_type
def standard_gcp_docker_worker(*, image=None, diskSizeGb=50, privileged=False, **cfg):
    """
    Build a standard docker-worker instance in GCP.

      image: image name (defaults to the standard image)
      diskSizeGb: boot disk size, in Gb (defaults to 50)
      privileged: true if this worker should allow privileged tasks (default false)
    """
    if image is None:
        image = DEFAUlT_GCP_DOCKER_WORKER_IMAGE
    rv = base_google_config(**cfg)
    for lc in rv['config']['launchConfigs']:
        lc['disks'][0]['initializeParams'] = {'sourceImage': image, 'diskSizeGb': diskSizeGb}
        lc["workerConfig"] = {
            "shutdown": {
                "enabled": True,
                "afterIdleSeconds": 900,
            },
        }
        if privileged:
            lc.setdefault('workerConfig', {}).setdefault('dockerConfig', {})['allowPrivileged'] = True

    return rv
