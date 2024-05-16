# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import attr

from tcadmin.util.config import ConfigDict
from .loader import loader


class ImageSets(ConfigDict):
    filename = "config/imagesets.yml"

    @attr.s
    class Item:
        name = attr.ib(type=str)
        workerImplementation = attr.ib(type=str)
        aws = attr.ib(type=dict, factory=lambda: {})
        azure = attr.ib(type=dict, factory=lambda: {})
        gcp = attr.ib(type=dict, factory=lambda: {})
        workerConfig = attr.ib(type=dict, factory=lambda: {})
