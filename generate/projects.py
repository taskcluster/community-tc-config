# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import jsone
import attr

from tcadmin.resources import Role, WorkerPool
from tcadmin.util.config import ConfigDict
from .loader import loader
from .workers import build_worker_pool

class Projects(ConfigDict):

    filename = "config/projects.yml"

    @attr.s
    class Item:
        name = attr.ib(type=str)
        adminRoles = attr.ib(type=list, factory=lambda: [])
        workerPools = attr.ib(type=dict, factory=lambda: {})


async def update_resources(resources):
    projects = Projects.load(loader)

    await generate_parameterized_roles(resources)
    await generate_group_roles(resources, projects)

    for project in projects.values():
        await generate_project(resources, project)


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
    for project in projects.values():
        for role in project.adminRoles:
            assert any(role.startswith(p) for p in prefixes)
            by_role.setdefault(role, []).append(project.name)

    for roleId, project_names in by_role.items():
        resources.add(Role(
            roleId=roleId,
            description="",
            scopes=['assume:project-admin:{}'.format(p) for p in project_names],
        ))


async def generate_project(resources, project):
    if project.workerPools:
        resources.manage('WorkerPool=proj-{}/.*'.format(project.name))
        await generate_project_worker_pools(resources, project)


async def generate_project_worker_pools(resources, project):
    for name, worker_pool in project.workerPools.items():
        worker_pool_id = 'proj-{}/{}'.format(project.name, name)
        worker_pool['description'] = "Workers for " + project.name
        resources.add(build_worker_pool(worker_pool_id, worker_pool))
