# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import jsone
import attr
import re

from tcadmin.resources import Role, Client, WorkerPool
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
        clients = attr.ib(type=dict, factory=lambda: {})
        grants = attr.ib(type=list, factory=lambda: [])
        externallyManaged = attr.ib(type=bool, default=False)


async def update_resources(resources):
    projects = await Projects.load(loader)

    for project in projects.values():
        for roleId in project.adminRoles:
            assert any(roleId.startswith(p) for p in ADMIN_ROLE_PREFIXES)
            resources.add(Role(
                roleId=roleId,
                description="",
                scopes=['assume:project-admin:{}'.format(project.name)]))
        if project.workerPools:
            for name, worker_pool in project.workerPools.items():
                worker_pool_id = 'proj-{}/{}'.format(project.name, name)
                if project.externallyManaged:
                    resources.manage('WorkerPool={}'.format(worker_pool_id))
                worker_pool['description'] = "Workers for " + project.name
                resources.add(build_worker_pool(worker_pool_id, worker_pool))
        if project.clients:
            for name, info in project.clients.items():
                clientId = 'project/{}/{}'.format(project.name, name)
                if project.externallyManaged:
                    resources.manage('Client={}'.format(client_id))
                description = info.get('description', '')
                scopes = info['scopes']
                resources.add(Client(
                    clientId=clientId,
                    description=description,
                    scopes=scopes))
        for grant in Grants.from_project(project):
            grant.update_resources(resources)


async def get_externally_managed_resource_patterns():
    "Get a list of regular expressions for resources that are externally managed"
    projects = await Projects.load(loader)
    patterns = []
    for project in projects.values():
        if not project.externallyManaged:
            continue
        name = re.escape(project.name)
        # this list corresponds to that for project-admin in config/grants.yml
        patterns.append(r"Role=project:{}:.*".format(name))
        patterns.append(r"Client=project/{}/.*".format(name))
        patterns.append(r"WorkerPool=proj-{}/.*".format(name))
        patterns.append(r"Hook=project-{}/.*".format(name))
        patterns.append(r"Role=hook-id:project-{}/.*".format(name))

    return patterns
