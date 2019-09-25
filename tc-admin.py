# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import jsone

from tcadmin.appconfig import AppConfig
from tcadmin.resources import Role, WorkerPool

appconfig = AppConfig()

projects = {
    'taskcluster': {
        'admin-roles': ['github-team:taskcluster/core', 'mozilla-group:team_taskcluster'],
        'worker-pools': {
            'ci': {
                "$mergeDeep": [
                    {"$eval": "definitions['standard-docker-worker']"},
                    {
                        'base': 'standard-docker-worker',
                        'owner': 'taskcluster-notifications+workers@mozilla.com',
                        'email_on_error': False,
                    }
                ]
            },
        },
    },
}

worker_pool_definitions = {
    'standard-docker-worker': {
        'description': '',
        'owner': 'nobody@mozilla.com',
        'provider_id': 'community-tc-workers',
	'config': {
	    "maxCapacity": 5,
	    "minCapacity": 0,
	    "capacityPerInstance": 1,
	    "machineType": "custom-32-29440",
	    "regions": ["us-east1"],
	    "scheduling": {
		"onHostMaintenance": "terminate",
	    },
	    "userData": {},
	    "disks": [{
		"type": "PERSISTENT",
		"boot": True,
		"autoDelete": True,
		"initializeParams": {
		    "sourceImage": "global/images/taskcluster-worker-googlecompute-2019-09-04t19-01-49z",
		    "diskSizeGb": 50
		    },
	    }],
	    "networkInterfaces": [{
		"accessConfigs": [{
			"type": "ONE_TO_ONE_NAT"
		    }],
	    }],
	},
        'email_on_error': False,
    },
}

@appconfig.generators.register
async def generate_projects(resources):
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
            "worker-manager:update-worker-type:proj-<..>", # old
            "worker-manager:create-worker-pool:proj-<..>",
            "worker-manager:update-worker-pool:proj-<..>",
            "worker-manager:update-worker-pool:proj-<..>",
            "worker-manager:create-worker:proj-<..>",

            # project-specific worker pools secrets
            "secrets:get:worker-pool:proj-<..>",
            "secrets:set:worker-pool:proj-<..>",

            # project-specific secrets
            "secrets:get:project/<..>/*",
            "secrets:set:project/<..>/*",
        ]))


async def generate_group_roles(resources, projects):
    prefixes = [
        'github-org-admin:',
        'github-team:',
        'login-identity:',
        'mozilla-group:',
        'mozillians-group:',
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

