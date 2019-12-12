# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

from tcadmin.resources import WorkerPool, Secret, Role

import copy, hashlib, json, os
import yaml

CLOUD_FUNCS = {}
WORKER_IMPLEMENTATION_FUNCS = {}


def cloud(fn):
    """
    Register a cloud config generator. This function takes keyword arguments
    based on the configuration in `projects.yml`, plus `secret_values`; an
    instance of SecretValues (or `None` if running without secrets), plus
    `image_set`; an instance of the ImageSets.Item class. It should return a
    dictionary with keys:
     - providerId - passed to worker-manager
     - config - passed to worker-manager
     - secret - content of the `worker-pool:<workerPoolId>` secret (optional)
     - scopes - any additional scopes required for workers in this cloud
    """
    CLOUD_FUNCS[fn.__name__] = fn
    return fn


def worker_implementation(fn):
    """
    Register a worker implementation generator. This function takes keyword
    arguments based on the configuration in `projects.yml`, plus
    `secret_values`; an instance of SecretValues (or `None` if running without
    secrets), plus `wp`; the returned value from the cloud generator (see
    above). It should return a dictionary with keys:
     - providerId - passed to worker-manager
     - config - passed to worker-manager
     - secret - content of the `worker-pool:<workerPoolId>` secret (optional)
     - scopes - any additional scopes required for workers with this
                implementation
    """
    WORKER_IMPLEMENTATION_FUNCS[fn.__name__] = fn
    return fn


def merge(*dicts):
    """
    Returns a new dict containing deep merge of dicts. Source dicts are not
    altered. Array values inside dicts are not merged. Values in earlier dicts
    take precedence over values in later dicts. At least two dicts required.
    """

    assert len(dicts) >= 2

    if len(dicts) > 2:
        return merge(dicts[0], merge(*dicts[1:]))

    result = copy.deepcopy(dicts[1])
    for key, value in dicts[0].items():
        if isinstance(value, dict):
            # get node or create one
            node = result.setdefault(key, {})
            result[key] = merge(value, node)
        else:
            result[key] = value

    return result


def build_worker_pool(workerPoolId, cfg, secret_values, image_set):
    try:
        wp = CLOUD_FUNCS[cfg["cloud"]](
            secret_values=secret_values, image_set=image_set, **cfg,
        )

        for launchConfig in wp["config"]["launchConfigs"]:
            launchConfig["workerConfig"] = merge(
                # The order is important here: earlier entries take precendence
                # over later entries.
                cfg.get("workerConfig", {}),
                image_set.workerConfig,
                launchConfig.get("workerConfig", {}),
            )

        wp = WORKER_IMPLEMENTATION_FUNCS[
            image_set.workerImplementation.replace("-", "_")
        ](secret_values=secret_values, wp=wp, **cfg,)
    except Exception as e:
        raise RuntimeError(
            "Error generating worker pool configuration for {}".format(workerPoolId)
        ) from e
    if secret_values:
        if "secret" in wp:
            secret = Secret(
                name="worker-pool:{}".format(workerPoolId), secret=wp.pop("secret")
            )
        else:
            secret = None
    else:
        secret = Secret(name="worker-pool:{}".format(workerPoolId))

    scopes = wp.pop("scopes")
    if scopes:
        role = Role(
            roleId="worker-pool:{}".format(workerPoolId),
            description="Scopes for image set `{}` and cloud `{}`.".format(
                image_set.name, cfg["cloud"]
            ),
            scopes=scopes,
        )
    else:
        role = None

    workerpool = WorkerPool(
        workerPoolId=workerPoolId,
        description=cfg.get("description", ""),
        owner=cfg.get("owner", "nobody@mozilla.com"),
        emailOnError=cfg.get("emailOnError", False),
        **wp,
    )

    return workerpool, secret, role


@cloud
def gcp(
    *,
    image_set=None,
    minCapacity=0,
    maxCapacity=None,
    machineType="zones/{zone}/machineTypes/n1-standard-4",
    diskSizeGb=50,
    **cfg,
):
    """
    Build a worker pool in Google.

      image_set: ImageSets.Item class instance with worker config, image names etc
      minCapacity: minimum capacity to run at any time (default 0)
      maxCapacity: maximum capacity to run at any time (required)
      machineType: fully qualified gcp machine type name (default
                   `zones/{zone}/machineTypes/n1-standard-4`)
      diskSizeGb: boot disk size, in GB (defaults to 50)
    """

    image = image_set.gcp["image"]

    GOOGLE_PROVIDER = "community-tc-workers-google"

    GOOGLE_REGIONS_ZONES = {
        "us-east1": ["b", "c", "d"],
        "us-east4": ["a", "b", "c"],
    }

    GOOGLE_ZONES_REGIONS = [
        ("{}-{}".format(region, zone), region)
        for region, zones in sorted(GOOGLE_REGIONS_ZONES.items())
        for zone in zones
    ]

    assert maxCapacity, "must give a maxCapacity"
    rv = {
        "providerId": GOOGLE_PROVIDER,
        "config": {
            "maxCapacity": maxCapacity,
            "minCapacity": minCapacity,
            "launchConfigs": [
                {
                    "capacityPerInstance": 1,
                    "machineType": machineType.format(zone=zone),
                    "region": region,
                    "zone": zone,
                    "scheduling": {"onHostMaintenance": "terminate"},
                    "disks": [
                        {
                            "type": "PERSISTENT",
                            "boot": True,
                            "autoDelete": True,
                            # "initializeParams": ..
                        }
                    ],
                    "networkInterfaces": [
                        {"accessConfigs": [{"type": "ONE_TO_ONE_NAT"}]}
                    ],
                }
                for zone, region in GOOGLE_ZONES_REGIONS
            ],
        },
        "scopes": [],
    }
    for lc in rv["config"]["launchConfigs"]:
        lc["disks"][0]["initializeParams"] = {
            "sourceImage": image,
            "diskSizeGb": diskSizeGb,
        }

    return rv


@cloud
def aws(
    *,
    image_set=None,
    regions=None,
    instanceTypes={"m3.2xlarge": 1},
    securityGroup="no-inbound",
    minCapacity=0,
    maxCapacity=None,
    **cfg,
):
    """
    Build a worker pool in AWS.

      image_set: ImageSets.Item class instance with worker config, image names etc
      regions: regions to deploy to (required)
      instanceTypes: dict of instance types to provision, values are
                     capacityPerInstance (required)
      securityGroup: name of the security group to appply (default no-inbound)
      minCapacity: minimum capacity to run at any time (default 0)
      maxCapacity: maximum capacity to run at any time (required)
    """

    assert maxCapacity, "must give a maxCapacity"
    assert instanceTypes, "must give instanceTypes"

    AWS_PROVIDER = "community-tc-workers-aws"

    # Use local yaml file for AWS network constants
    # These constants are set in a separate file to be used by external services
    # like the fuzzing team decision tasks
    _config_path = os.path.join(os.path.dirname(__file__), "aws.yml")
    assert os.path.exists(_config_path), "Missing aws config in {}".format(_config_path)
    aws_config = yaml.safe_load(open(_config_path))

    # by default, deploy where there are images
    if "regions" not in cfg:
        regions = list(image_set.aws["amis"])
    assert regions, "must give regions"

    imageIds = image_set.aws["amis"]
    assert imageIds, "must give imageIds"

    launchConfigs = []
    for region in regions:
        groupId = aws_config["security_groups"][region][securityGroup]
        for az, subnetId in aws_config["subnets"][region].items():
            for instanceType, capacityPerInstance in instanceTypes.items():
                # Instance type m3.2xlarge isn't available in us-east-1[a,f], so
                # filter out that combination.
                if instanceType == "m3.2xlarge" and az in [
                    "us-east-1a",
                    "us-east-1f",
                    "us-west-2d",
                ]:
                    continue
                launchConfig = {
                    "capacityPerInstance": capacityPerInstance,
                    "region": region,
                    "launchConfig": {
                        "ImageId": imageIds[region],
                        "Placement": {"AvailabilityZone": az},
                        "SubnetId": subnetId,
                        "SecurityGroupIds": [groupId],
                        "InstanceType": instanceType,
                        "InstanceMarketOptions": {"MarketType": "spot"},
                    },
                }
                launchConfigs.append(launchConfig)

    return {
        "providerId": AWS_PROVIDER,
        "config": {
            "minCapacity": minCapacity,
            "maxCapacity": maxCapacity,
            "launchConfigs": launchConfigs,
        },
        "scopes": [],
    }


@worker_implementation
def generic_worker(wp, **cfg):

    for launchConfig in wp["config"]["launchConfigs"]:
        launchConfig["workerConfig"] = merge(
            launchConfig["workerConfig"],  # takes precendence
            {
                "genericWorker": {
                    "config": {
                        "wstAudience": "communitytc",
                        "wstServerURL": "https://community-websocktunnel.services.mozilla.com",
                    },
                },
            },
        )

    # Generate unique deployment ID based on hash of launch config. Note, this
    # isn't perfect, since it may not always be necessary to respawn workers in
    # all regions for any launch config change, but it is a safe approach that
    # favours over-rotating workers over under-rotating workers in cases of
    # uncertainty. Note, deploymentId needs to be the same for all regions,
    # since workers check the deploymentId of the first launchConfig,
    # regardless of the region they are in.
    hashedConfig = hashlib.sha256(
        json.dumps(wp["config"]["launchConfigs"], sort_keys=True).encode("utf8")
    ).hexdigest()

    for launchConfig in wp["config"]["launchConfigs"]:
        launchConfig["workerConfig"]["genericWorker"]["config"][
            "deploymentId"
        ] = hashedConfig[:16]

    # The sentry project may be specified in the image set definition
    # (/config/imagesets.yml), or in the worker pool definition
    # (/config/projects.yml) so isn't necessarily "generic-worker". Note, we
    # don't include "sentryProject": "generic-worker" in fallback settings
    # above, since generic-worker has this default already, and this keeps the
    # config sections smaller/simpler.
    sentryProject = launchConfig["workerConfig"]["genericWorker"]["config"].get(
        "sentryProject", "generic-worker"
    )
    wp["scopes"].append("auth:sentry:" + sentryProject)

    return wp


@worker_implementation
def docker_worker(wp, **cfg):

    for launchConfig in wp["config"]["launchConfigs"]:
        launchConfig["workerConfig"] = merge(
            launchConfig["workerConfig"],  # takes precendence
            {"shutdown": {"enabled": True, "afterIdleSeconds": 900}},
        )

    if cfg["secret_values"]:
        wp["secret"] = cfg["secret_values"].render(
            {
                "config": {
                    "statelessHostname": {
                        "secret": "$stateless-dns-secret",
                        "domain": "taskcluster-worker.net",
                    },
                },
            }
        )

    wp["scopes"].append("auth:sentry:docker-worker")

    return wp
