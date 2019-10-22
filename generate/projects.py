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
from .grants import Grants

ADMIN_ROLE_PREFIXES = [
    'github-org-admin:',
    'github-team:',
    'login-identity:',
]

class Projects(ConfigDict):

    filename = "config/projects.yml"

    @attr.s
    class Item:
        name = attr.ib(type=str)
        adminRoles = attr.ib(type=list, factory=lambda: [])
        workerPools = attr.ib(type=dict, factory=lambda: {})
        grants = attr.ib(type=list, factory=lambda: [])


async def update_resources(resources):
    resources.manage(r"Role=project-admin:.*")
    resources.manage('Role=repo:.*')
    for prefix in ADMIN_ROLE_PREFIXES:
        resources.manage(r'Role={}.*'.format(prefix))

    projects = await Projects.load(loader)

    for project in projects.values():
        for roleId in project.adminRoles:
            assert any(roleId.startswith(p) for p in ADMIN_ROLE_PREFIXES)
            resources.add(Role(
                roleId=roleId,
                description="", 
                scopes=['assume:project-admin:{}'.format(project.name)]))
        if project.workerPools:
            resources.manage('WorkerPool=proj-{}/.*'.format(project.name))
            for name, worker_pool in project.workerPools.items():
                worker_pool_id = 'proj-{}/{}'.format(project.name, name)
                worker_pool['description'] = "Workers for " + project.name
                resources.add(build_worker_pool(worker_pool_id, worker_pool))
        for grant in Grants.from_project(project):
            grant.update_resources(resources)
