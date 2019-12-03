# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

from tcadmin.resources import WorkerPool, Secret

import hashlib

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
    """
    CLOUD_FUNCS[fn.__name__] = fn
    return fn


def worker_implementation(fn):
    """
    Register a worker implementation generator. This function takes keyword
    arguments based on the configuration in `projects.yml`, plus
    `secret_values`; an instance of SecretValues (or `None` if running without
    secrets), plus `image_set`; an instance of the ImageSets.Item class, plus
    `wp`; the returned value from the cloud generator (see above). It should
    return a dictionary with keys:
     - providerId - passed to worker-manager
     - config - passed to worker-manager
     - secret - content of the `worker-pool:<workerPoolId>` secret (optional)
    """
    WORKER_IMPLEMENTATION_FUNCS[fn.__name__] = fn
    return fn


def merge(source, destination):
    """
    Recursively merges a source and destination dict. Note, array values are
    not merged; arrays in source will be replaced by arrays in destination.
    """
    for key, value in source.items():
        if isinstance(value, dict):
            # get node or create one
            node = destination.setdefault(key, {})
            merge(value, node)
        else:
            destination[key] = value

    return destination


def build_worker_pool(workerPoolId, cfg, secret_values, image_set):
    try:
        wp = CLOUD_FUNCS[cfg["cloud"]](
            secret_values=secret_values, image_set=image_set, **cfg,
        )
        wp = WORKER_IMPLEMENTATION_FUNCS[
            image_set.workerImplementation.replace("-", "_")
        ](secret_values=secret_values, image_set=image_set, wp=wp, **cfg,)
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

    workerpool = WorkerPool(
        workerPoolId=workerPoolId,
        description=cfg.get("description", ""),
        owner=cfg.get("owner", "nobody@mozilla.com"),
        emailOnError=cfg.get("emailOnError", False),
        **wp,
    )

    return workerpool, secret


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
    }
    for lc in rv["config"]["launchConfigs"]:
        lc["disks"][0]["initializeParams"] = {
            "sourceImage": image,
            "diskSizeGb": diskSizeGb,
        }
        lc["workerConfig"] = {
            "shutdown": {"enabled": True, "afterIdleSeconds": 900},
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

    AWS_SUBNETS = {
        "us-west-1": {
            "us-west-1a": "subnet-0e43a99e9c865689e",
            "us-west-1b": "subnet-0a5344f7003aede7c",
        },
        "us-west-2": {
            "us-west-2a": "subnet-048a61782df5ba378",
            "us-west-2b": "subnet-05053e2898fc744e9",
            "us-west-2c": "subnet-036a0812d241733ef",
            "us-west-2d": "subnet-0fc336d9e5934c913",
        },
        "us-east-1": {
            "us-east-1a": "subnet-0ab0ba0d9836bb7ab",
            "us-east-1b": "subnet-08c284e43fd180150",
            "us-east-1c": "subnet-0034e6efd82d24939",
            "us-east-1d": "subnet-05a055adc7a81adc0",
            "us-east-1e": "subnet-03bbdcf0ec23f8caa",
            "us-east-1f": "subnet-0cc340c5cf9346dcc",
        },
        "us-east-2": {
            "us-east-2a": "subnet-05205c91d6a9f06e6",
            "us-east-2b": "subnet-082be4d0d5e7e4d58",
            "us-east-2c": "subnet-01eb0c6a5e15846db",
        },
    }

    AWS_SECURITY_GROUPS = {
        "us-west-1": {
            "no-inbound": "sg-00c4014bc978171d5",
            "docker-worker": "sg-0d2ff88f36a05b499",
        },
        "us-west-2": {
            "no-inbound": "sg-0659c2937ecbe7254",
            "docker-worker": "sg-0f8a656368c567425",
        },
        "us-east-1": {
            "no-inbound": "sg-07f7d21a488e192c6",
            "docker-worker": "sg-08fea1235cf66b102",
        },
        "us-east-2": {
            "no-inbound": "sg-00a9d64b3595c5088",
            "docker-worker": "sg-0388de36e2f30ced2  u",
        },
    }

    # by default, deploy where there are images
    if "regions" not in cfg:
        regions = list(image_set.aws["amis"])
    assert regions, "must give regions"

    imageIds = image_set.aws["amis"]
    assert imageIds, "must give imageIds"

    launchConfigs = []
    for region in regions:
        groupId = AWS_SECURITY_GROUPS[region][securityGroup]
        for az, subnetId in AWS_SUBNETS[region].items():
            for instanceType, capacityPerInstance in instanceTypes.items():
                # Instance type m3.2xlarge isn't available in us-east-1[a,f], so
                # filter out that combination.
                if instanceType == "m3.2xlarge" and az in ["us-east-1a", "us-east-1f"]:
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
    }


@worker_implementation
def generic_worker(image_set, wp, **cfg):

    # hashed = hashlib.sha256(json.dumps(configs, sort_keys=True).encode("utf8")).hexdigest()
    # generic_worker_config["deploymentId"] = hashed[:16]

    for launchConfig in wp["config"]["launchConfigs"]:
        launchConfig["workerConfig"] = {
            "genericWorker": {
                "config": {
                    "deploymentId": "community-tc-config",
                    "sentryProject": "generic-worker",
                    "wstAudience": "communitytc",
                    "wstServerURL": "https://community-websocktunnel.services.mozilla.com",
                },
            },
        }
        launchConfig["workerConfig"] = merge(
            launchConfig["workerConfig"], image_set.workerConfig
        )
        if "workerConfig" in cfg:
            launchConfig["workerConfig"] = merge(
                launchConfig["workerConfig"], cfg["workerConfig"]
            )

    return wp


@worker_implementation
def docker_worker(image_set, wp, **cfg):

    for launchConfig in wp["config"]["launchConfigs"]:
        launchConfig["workerConfig"] = merge(
            launchConfig["workerConfig"], image_set.workerConfig
        )
        if "workerConfig" in cfg:
            launchConfig["workerConfig"] = merge(
                launchConfig["workerConfig"], cfg["workerConfig"]
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

    return wp
