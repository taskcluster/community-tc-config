# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import re
import os
import sys

from tcadmin.appconfig import AppConfig

from . import projects, grants


async def update_resources(resources):
    # Set up the resources to manage everything *except* externally managed
    # resources
    externally_managed_patterns = (
        await projects.get_externally_managed_resource_patterns()
    )

    # ..and except static clients and user-generatd clients
    externally_managed_patterns.append("Client=(static|github)/.*")

    em_bar = "|".join(externally_managed_patterns)
    resources.manage(re.compile(r"(?!{}).*".format(em_bar)))

    if AppConfig.current().options.get("with_secrets"):
        print(
            "Use --without-secrets; secret management is not yet supported",
            file=sys.stderr,
        )
        os._exit(1)

    await projects.update_resources(resources)
    await grants.update_resources(resources)
