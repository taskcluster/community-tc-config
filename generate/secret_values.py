# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

import subprocess
import sys
import yaml

PASSWORDSTORE_NAME = "community-tc/secret-values.yml"


class SecretValues:
    """A container for secret values.  This is loaded only when --with-secrets,
    and requires `passwordstore` support."""

    def __init__(self):
        print("Fetching secrets with passwordstore", file=sys.stderr)
        secret_values_yml = subprocess.check_output(["pass", PASSWORDSTORE_NAME])
        self.values = yaml.safe_load(secret_values_yml)
        print("Secrets fetched", file=sys.stderr)

    def get(self, name, default=None):
        return self.values.get(name, default)

    def __getitem__(self, name):
        return self.values[name]

    def render(self, template):
        """
        Replace '$secretname' with that secret value in the given recursive data structure.  Values
        that begin with `$` can be escaped with `$$`.
        """

        def recur(value):
            if isinstance(value, str):
                if value.startswith("$"):
                    if value.startswith("$$"):
                        return value[1:]
                    else:
                        return self[value[1:]]
            elif isinstance(value, list):
                return [recur(v) for v in value]
            elif isinstance(value, dict):
                return {k: recur(v) for k, v in value.items()}
            return value

        return recur(template)
