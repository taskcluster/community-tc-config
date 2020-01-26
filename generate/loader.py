# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

from tcadmin.util.config import LocalLoader
import os

loader = LocalLoader()


class YamlDirectory(dict):
    """
    Similar to tc-admin's ConfigDict, this loads data from all `.yml` files in
    `cls.directory`, merging the results.
    """

    @classmethod
    async def load(cls, loader):
        res = {}
        for file in os.listdir(cls.directory):
            if not file.endswith(".yml"):
                continue
            file = os.path.join(cls.directory, file)
            data = await loader.load(file, parse="yaml")
            assert isinstance(data, dict), "{} is not a YAML object".format(
                cls.filename
            )
            for k, v in data.items():
                if k in res:
                    raise RuntimeError(f"{file}: another file already defined key {k}")
                res[k] = cls.Item(k, **cls.transform_item(v))
        return res

    @classmethod
    def transform_item(cls, item):
        return item
