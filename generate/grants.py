# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import attr
import re

from tcadmin.resources import Role
from tcadmin.util.config import ConfigList
from .loader import loader


def make_list(val):
    if type(val) == list:
        return val
    return [val]


class Grants(ConfigList):

    filename = "config/grants.yml"

    @attr.s
    class Item:
        grant = attr.ib(type=list, converter=make_list)
        to = attr.ib(type=list, converter=make_list)

        def update_resources(self, resources):
            scopes = self.grant
            for roleId in self.to:
                id = f"Role={roleId}"
                if not resources.is_managed(id):
                    resources.manage(re.escape(id))
                resources.add(Role(roleId=roleId, description="", scopes=scopes))

    @classmethod
    def from_project(cls, project):
        return cls(cls.Item(**g) for g in project.grants)


async def update_resources(resources, secret_values):
    for grant in await Grants.load(loader):
        grant.update_resources(resources)
