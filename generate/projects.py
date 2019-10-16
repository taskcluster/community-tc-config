# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import jsone

from tcadmin.resources import Role, WorkerPool


projects = {
    'taskcluster': {
        'admin-roles': ['github-team:taskcluster/core'],
        'worker-pools': {
            'ci': {
                "$mergeDeep": [
                    {"$eval": "definitions['standard-docker-worker']"},
                    {
                        'base': 'standard-docker-worker',
                        'owner': 'taskcluster-notifications+workers@mozilla.com',
                        'email_on_error': False,
                        'config': {
                            'workerConfig': {
                                'dockerConfig': {
                                    'allowPrivileged': True,
                                },
                            },
                        },
                    },
                ],
            },
        },
    },
}

google_regions_zones = {
    "us-east1": ["b", "c", "d"],
    "us-east4": ["a", "b", "c"],
}

google_zones_regions = []
for region, zones in google_regions_zones.items():
    for zone in zones:
        google_zones_regions.append(("{}-{}".format(region, zone), region))

worker_pool_definitions = {
    'standard-docker-worker': {
        'description': '',
        'owner': 'nobody@mozilla.com',
        'provider_id': 'community-tc-workers-google',
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
                    "workerConfig": {
                        "shutdown": {
                            "enabled": True,
                            "afterIdleSeconds": 900,
                        },
                    },
                    "disks": [{
                        "type": "PERSISTENT",
                        "boot": True,
                        "autoDelete": True,
                        "initializeParams": {
                            "sourceImage": "projects/taskcluster-imaging/global/images/docker-worker-gcp-googlecompute-2019-10-08t02-31-36z",
                            "diskSizeGb": 50
                            },
                    }],
                    "networkInterfaces": [{
                        "accessConfigs": [{
                            "type": "ONE_TO_ONE_NAT"
                        }],
                    }],
                }
                for zone, region in google_zones_regions
            ]
        },
        'email_on_error': False,
    },
}

async def update_resources(resources):
    await generate_parameterized_roles(resources)
    await generate_group_roles(resources, projects)

    for project, cfg in projects.items():
        await generate_project(resources, project, cfg)


async def generate_parameterized_roles(resources):
    resources.manage(r"Role=project-admin:.*")

    # add a single parameterized role to generate most project-admin scopes
    resources.add(Role(
        roleId="project-admin:*",
        description="Scopes for administrators of projects; this gives complete control over everything related to the project.",
        scopes=[
            # project-specific scopes
            "project:<..>:*",

            # project-specific roles
            "assume:project:<..>:*",
            "auth:create-role:project:<..>:*",
            "auth:delete-role:project:<..>:*",
            "auth:update-role:project:<..>:*",

            # project-specific clients
            "auth:create-client:project/<..>/*",
            "auth:delete-client:project/<..>/*",
            "auth:disable-client:project/<..>/*",
            "auth:enable-client:project/<..>/*",
            "auth:update-client:project/<..>/*",
            "auth:reset-access-token:project/<..>/*",

            # project-specific taskQueueIds
            "queue:create-task:lowest:proj-<..>/*",
            "queue:create-task:very-low:proj-<..>/*",
            "queue:create-task:low:proj-<..>/*",
            "queue:create-task:medium:proj-<..>/*",
            "queue:create-task:high:proj-<..>/*",
            "queue:create-task:very-high:proj-<..>/*",
            "queue:create-task:highest:proj-<..>/*",
            "queue:quarantine-worker:proj-<..>/*",

            # project-specific private artifacts
            "queue:get-artifact:project/<..>/*",

            # project-specific hooks
            "assume:hook-id:project-<..>/*",
            "auth:create-role:hook-id:project-<..>/*",
            "auth:delete-role:hook-id:project-<..>/*",
            "auth:update-role:hook-id:project-<..>/*",
            "hooks:modify-hook:project-<..>/*",
            "hooks:trigger-hook:project-<..>/*",

            # project-specific index routes
            "index:insert-task:project.<..>.*",
            "queue:route:index.project.<..>.*",

            # project-specific worker pools and workers
            "worker-manager:create-worker-type:proj-<..>", # old, see https://bugzilla.mozilla.org/show_bug.cgi?id=1583935
            "worker-manager:update-worker-type:proj-<..>", # old
            "worker-manager:create-worker-pool:proj-<..>",
            "worker-manager:update-worker-pool:proj-<..>",
            "worker-manager:create-worker:proj-<..>",

            # project-specific worker pools secrets
            "secrets:get:worker-pool:proj-<..>",
            "secrets:set:worker-pool:proj-<..>",

            # project-specific secrets
            "secrets:get:project/<..>/*",
            "secrets:set:project/<..>/*",

            # allow all caches, since workers are per-project
            'docker-worker:cache:*',
            'generic-worker:cache:*',
        ]))


async def generate_group_roles(resources, projects):
    prefixes = [
        'github-org-admin:',
        'github-team:',
        'login-identity:',
    ]
    for prefix in prefixes:
        resources.manage(r'Role={}.*'.format(prefix))

    by_role = {}
    for project, cfg in projects.items():
        for role in cfg.get('admin-roles', []):
            assert any(role.startswith(p) for p in prefixes)
            by_role.setdefault(role, []).append(project)

    for roleId, project_names in by_role.items():
        resources.add(Role(
            roleId=roleId,
            description="",
            scopes=['assume:project-admin:{}'.format(p) for p in project_names],
        ))


async def generate_project(resources, project, cfg):
    if 'worker-pools' in cfg:
        resources.manage('WorkerPool=proj-.*')
        await generate_project_worker_pools(resources, project, cfg['worker-pools'])


async def generate_project_worker_pools(resources, project, worker_pools):
    for name, worker_pool in worker_pools.items():
        worker_pool = jsone.render(worker_pool, {'definitions': worker_pool_definitions})
        resources.add(WorkerPool(
            workerPoolId='proj-{}/{}'.format(project, name),
            description=worker_pool['description'] or 'Workers for ' + project,
            owner=worker_pool['owner'],
            providerId=worker_pool['provider_id'],
            config=worker_pool['config'],
            emailOnError=worker_pool['email_on_error']))
