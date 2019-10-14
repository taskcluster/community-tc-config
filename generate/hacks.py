# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import jsone
import textwrap

from tcadmin.resources import Role, WorkerPool


async def update_resources(resources):
    resources.add(Role(
        roleId="login-identity:TEMP",
        description=textwrap.dedent("""\
            This ensures that the web-server service has the scopes added
            in https://github.com/taskcluster/taskcluster/commit/bbb0f0a38b1444c7653cce6d00af5abd806efe90,
            and can be removed once that is merged."""),
        scopes=[
            "assume:github-org-admin:*",
            "assume:github-team:*",
        ]))
