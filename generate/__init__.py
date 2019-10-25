# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import re

from . import projects, login_identity, grants


async def update_resources(resources):
    # Set up the resources to manage everything *except* externally managed resources
    externally_managed_patterns = await projects.get_externally_managed_resource_patterns()
    # ..and except static clients and user-generatd clients
    externally_managed_patterns.append('Client=(static|github)/.*')

    em_bar = '|'.join(externally_managed_patterns)
    resources.manage(re.compile(r"(?!{}).*".format(em_bar)))

    await projects.update_resources(resources)
    await login_identity.update_resources(resources)
    await grants.update_resources(resources)
