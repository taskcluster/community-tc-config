# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

from tcadmin.appconfig import AppConfig

import generate.projects


appconfig = AppConfig()

appconfig.generators.register(generate.projects.update_resources)
