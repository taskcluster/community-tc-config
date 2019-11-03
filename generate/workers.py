# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

from tcadmin.resources import WorkerPool

TYPES = {}

AWS_PROVIDER = 'community-tc-workers-aws'

AWS_SUBNETS = {
    'us-west-1': {
        'us-west-1a': 'subnet-0e43a99e9c865689e',
        'us-west-1b': 'subnet-0a5344f7003aede7c',
    },
    'us-west-2': {
        'us-west-2a': 'subnet-048a61782df5ba378',
        'us-west-2b': 'subnet-05053e2898fc744e9',
        'us-west-2c': 'subnet-036a0812d241733ef',
        'us-west-2d': 'subnet-0fc336d9e5934c913',
    },
    'us-east-1': {
        'us-east-1a': 'subnet-0ab0ba0d9836bb7ab',
        'us-east-1b': 'subnet-08c284e43fd180150',
        'us-east-1c': 'subnet-0034e6efd82d24939',
        'us-east-1d': 'subnet-05a055adc7a81adc0',
        'us-east-1e': 'subnet-03bbdcf0ec23f8caa',
        'us-east-1f': 'subnet-0cc340c5cf9346dcc',
    },
    'us-east-2': {
        'us-east-2a': 'subnet-05205c91d6a9f06e6',
        'us-east-2b': 'subnet-082be4d0d5e7e4d58',
        'us-east-2c': 'subnet-01eb0c6a5e15846db',
    },
}

AWS_SECURITY_GROUPS = {
    'us-west-1': {
        'no-inbound': 'sg-00c4014bc978171d5',
        'docker-worker': 'sg-0d2ff88f36a05b499',
    },
    'us-west-2': {
        'no-inbound': 'sg-0659c2937ecbe7254',
        'docker-worker': 'sg-0f8a656368c567425',
    },
    'us-east-1': {
        'no-inbound': 'sg-07f7d21a488e192c6',
        'docker-worker': 'sg-08fea1235cf66b102',
    },
    'us-east-2': {
        'no-inbound': 'sg-00a9d64b3595c5088',
        'docker-worker': 'sg-0388de36e2f30ced2  u',
    },
}

DEFAULT_AWS_WIN2012_GENERIC_WORKER_IMAGES = {
    # from https://bugzilla.mozilla.org/show_bug.cgi?id=1590910
    'us-east-1': 'ami-04ff4e4c220abce54',
    'us-west-1': 'ami-070ee00d395f493d3',
    'us-west-2': 'ami-02161407768d981ea',
}

GOOGLE_PROVIDER = 'community-tc-workers-google'

DEFAUlT_GOOGLE_DOCKER_WORKER_IMAGE = "projects/taskcluster-imaging/global/images/docker-worker-gcp-googlecompute-2019-10-08t02-31-36z"

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
    try:
        wp = TYPES[cfg['type']](**cfg)
    except Exception as e:
        raise RuntimeError('Error generating worker pool configuration for {}'.format(workerPoolId)) from e
    return WorkerPool(
        workerPoolId=workerPoolId,
        description=cfg.get('description', ''),
        owner=cfg.get('owner', 'nobody@mozilla.com'),
        emailOnError=cfg.get('emailOnError', False),
        **wp)


def base_google_config(*, minCapacity=0, maxCapacity=None, **cfg):
    """
    Build a base config for a Google instance

      minCapacity: minimum capacity to run at any time (default 0)
      maxCapacity: maximum capacity to run at any time (required)
    """
    assert maxCapacity, "must give a maxCapacity"
    return {
        'providerId': GOOGLE_PROVIDER,
        'config': {
            "maxCapacity": maxCapacity,
            "minCapacity": minCapacity,
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
    Build a standard docker-worker instance in Google.

      image: image name (defaults to the standard image)
      diskSizeGb: boot disk size, in Gb (defaults to 50)
      privileged: true if this worker should allow privileged tasks (default false)
      ..in addition to kwargs from base_google_config
    """
    if image is None:
        image = DEFAUlT_GOOGLE_DOCKER_WORKER_IMAGE
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


def base_aws_config(*, regions=None, imageIds=None, instanceTypes=None, securityGroup="no-inbound",
                    minCapacity=0, maxCapacity=None, **cfg):
    """
    Build a base for workers in AWS

      regions: regions to deploy to (required)
      imageIds: dict of AMIs, keyed by region (required)
      instanceTypes: dict of instance types to provision, values are capacityPerInstance (required)
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
                launchConfig = {
                    'capacityPerInstance': capacityPerInstance,
                    'region': region,
                    'launchConfig': {
                        "ImageId": imageIds[region],
                        "Placement": {"AvailabilityZone": az},
                        "SubnetId": subnetId,
                        "SecurityGroupIds": [groupId],
                        "InstanceType": instanceType,
                        "InstanceMarketOptions": {"MarketType": "spot"}
                    },
                }
                launchConfigs.append(launchConfig)

    return {
        'providerId': AWS_PROVIDER,
        'config': {
            'minCapacity': minCapacity,
            'maxCapacity': maxCapacity,
            'launchConfigs': launchConfigs
        },
    }


def base_aws_generic_worker_config(**cfg):
    """
    Build a base for generic-worker in AWS
    """

    # by default, deploy where there are images
    if 'regions' not in cfg and 'imageIds' in cfg:
        cfg['regions'] = list(cfg['imageIds'])

    rv = base_aws_config(**cfg)

    for launchConfig in rv['config']['launchConfigs']:
        launchConfig['workerConfig'] = {
            'genericWorker': {
                'config': {
                    "deploymentId": "community-tc-config",
                    "ed25519SigningKeyLocation": "C:\\generic-worker\\generic-worker-ed25519-signing-key.key",
                    "livelogExecutable": "C:\\generic-worker\\livelog.exe",
                    "sentryProject": "generic-worker",
                    "taskclusterProxyExecutable": "C:\\generic-worker\\taskcluster-proxy.exe",
                    "workerTypeMetadata": {},
                    'wstAudience': 'communitytc',
                    'wstServerURL': 'https://community-websocktunnel.services.mozilla.com',
                },
            },
        }
    return rv


@worker_pool_type
def standard_aws_generic_worker_win2012r2(**cfg):
    """
    Build a standard Win2012R2 worker instance in AWS
    """
    rv = base_aws_generic_worker_config(
        imageIds=DEFAULT_AWS_WIN2012_GENERIC_WORKER_IMAGES,
        instanceTypes={"m3.2xlarge": 1},
        **cfg)

    # instance type m3.2xlarge isn't available in this us-east-1a, so we filter
    # out that zone
    rv['config']['launchConfigs'] = [lc
            for lc in rv['config']['launchConfigs']
            if lc['launchConfig']['Placement']['AvailabilityZone'] != 'us-east-1a']

    return rv

@worker_pool_type
def aws_generic_worker_deepspeech_win(imageIds={}, **cfg):
    """
    Build a deepspeech windows worker instance in AWS, with images
    specified in the project config
    """
    rv = base_aws_generic_worker_config(
        imageIds=imageIds,
        instanceTypes={"m5d.2xlarge": 1},
        **cfg)

    return rv
