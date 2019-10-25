# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import jsone
import textwrap

from tcadmin.resources import Role, WorkerPool


users = {
    'github/28673|djmitche': [
        'queue:route:index.garbage.*',  # just for testing
    ],
}

async def update_resources(resources):
    resources.add(Role(
        roleId="login-identity:*",
        description=textwrap.dedent("""\
            Scopes for anyone who logs into the service;
            see [login-identities docs](https://docs.taskcluster.net/docs/manual/design/conventions/login-identities)."""),
        scopes=[
            'auth:create-client:<..>/*',
            'auth:delete-client:<..>/*',
            'auth:reset-access-token:<..>/*',
            'auth:update-client:<..>/*',
        ]))
