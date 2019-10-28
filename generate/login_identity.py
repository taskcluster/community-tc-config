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
