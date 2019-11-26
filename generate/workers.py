# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

from tcadmin.resources import WorkerPool, Secret

import hashlib

IMAGESET_CLOUD_FUNCS = {}
IMAGESET_WORKER_IMPLEMENTATION_FUNCS = {}

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


def imageset_cloud(fn):
    IMAGESET_CLOUD_FUNCS[fn.__name__] = fn
    return fn


def imageset_worker_implementation(fn):
    IMAGESET_WORKER_IMPLEMENTATION_FUNCS[fn.__name__] = fn
    return fn


def build_worker_pool(workerPoolId, cfg, secret_values):
    try:
        wp = IMAGESET_CLOUD_FUNCS[cfg["imageset"]["cloud"]](**cfg)
        wp.update(IMAGESET_WORKER_IMPLEMENTATION[cfg["imageset"]["worker-implementation"]](**cfg))
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


def base_google_config(
    *,
    minCapacity=0,
    maxCapacity=None,
    machineType="zones/{zone}/machineTypes/n1-standard-4",
    **cfg,
):
    """
    Build a base config for a Google instance

      minCapacity: minimum capacity to run at any time (default 0)
      maxCapacity: maximum capacity to run at any time (required)
    """
    assert maxCapacity, "must give a maxCapacity"
    return {
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


@imageset_cloud
def gcp(*, image=None, diskSizeGb=50, privileged=False, **cfg):
    """
    Build a standard docker-worker instance in Google.

      image: image name (defaults to the standard image)
      diskSizeGb: boot disk size, in Gb (defaults to 50)
      privileged: true if this worker should allow privileged tasks (default false)
      ..in addition to kwargs from base_google_config
    """
    rv = base_google_config(**cfg)
    for lc in rv["config"]["launchConfigs"]:
        lc["disks"][0]["initializeParams"] = {
            "sourceImage": image,
            "diskSizeGb": diskSizeGb,
        }
        lc["workerConfig"] = {
            "shutdown": {"enabled": True, "afterIdleSeconds": 900},
        }

    if cfg["secret_values"]:
        rv["secret"] = cfg["secret_values"].render(
            {
                "config": {
                    "statelessHostname": {
                        "secret": "$stateless-dns-secret",
                        "domain": "taskcluster-worker.net",
                    },
                },
            }
        )

    return rv


@imageset_cloud
def aws(
    *,
    regions=None,
    imageIds=None,
    instanceTypes=None,
    securityGroup="no-inbound",
    minCapacity=0,
    maxCapacity=None,
    **cfg,
):
    """
    Build a base for workers in AWS

      regions: regions to deploy to (required)
      imageIds: dict of AMIs, keyed by region (required)
      instanceTypes: dict of instance types to provision, values are
      capacityPerInstance (required)
      securityGroup: name of the security group to appply (default no-inbound)
      minCapacity: minimum capacity to run at any time (default 0)
      maxCapacity: maximum capacity to run at any time (required)
    """
    assert maxCapacity, "must give a maxCapacity"
    assert regions, "must give regions"
    assert imageIds, "must give imageIds"
    assert instanceTypes, "must give instanceTypes"

    launchConfigs = []
    for region in regions:
        groupId = AWS_SECURITY_GROUPS[region][securityGroup]
        for az, subnetId in AWS_SUBNETS[region].items():
            for instanceType, capacityPerInstance in instanceTypes.items():
                # Instance type m3.2xlarge isn't available in us-east-1a, so
                # filter out that combination.
                if az == "us-east-1a" and instanceType == "m3.2xlarge":
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

@imageset_worker_implementation
def generic_worker(platform, instanceTypes={"m3.2xlarge": 1}, workerConfig={}, **cfg):
    """
    Build a base for generic-worker in AWS
    """

    hashed = hashlib.sha256(json.dumps(configs, sort_keys=True).encode("utf8")).hexdigest()
    generic_worker_config["deploymentId"] = hashed[:16]

    # by default, deploy where there are images
    if "regions" not in cfg and "imageIds" in cfg:
        cfg["regions"] = list(cfg["imageIds"])

    rv = base_aws_config(**cfg)

    for launchConfig in rv["config"]["launchConfigs"]:
        launchConfig["workerConfig"] = {
            "genericWorker": {
                "config": {
                    "deploymentId": "community-tc-config",
                    "sentryProject": "generic-worker",
                    "wstAudience": "communitytc",
                    "wstServerURL": "https://community-websocktunnel.services.mozilla.com",
                }.update(GENERIC_WORKER_DEFAULT_CONFIG[platform]),
            },
        }.update(workerConfig)

    return rv


@worker_pool_type
def standard_aws_generic_worker_win2012r2(**cfg):
    """
    Build a standard Win2012R2 worker instance in AWS
    """
    rv = base_aws_generic_worker_config(
        imageIds=DEFAULT_AWS_WIN2012_GENERIC_WORKER_IMAGES,
        instanceTypes={"m3.2xlarge": 1},
        **cfg,
    )

    # instance type m3.2xlarge isn't available in this us-east-1a, so we filter
    # out that zone
    rv["config"]["launchConfigs"] = [
        lc
        for lc in rv["config"]["launchConfigs"]
        if lc["launchConfig"]["Placement"]["AvailabilityZone"] != "us-east-1a"
    ]

    return rv


@worker_pool_type
def aws_generic_worker_deepspeech_win(imageIds={}, **cfg):
    """
    Build a deepspeech windows worker instance in AWS, with images
    specified in the project config
    """
    rv = base_aws_generic_worker_config(
        imageIds=imageIds, instanceTypes={"m5d.2xlarge": 1}, **cfg
    )
>>>>>>> adb4ae97e42bcd19cb3b158cc7686607337c895f

    return rv
