# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import jsone
import textwrap

from tcadmin.resources import Role, WorkerPool


async def update_resources(resources):
    resources.manage("Role=worker-pool:*")
    resources.add(Role(
        roleId="worker-pool:*",
        description="Scopes for all workers in the deployment.",
        scopes=[
            "auth:websocktunnel-token:communitytc/*",
        ]))

