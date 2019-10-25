# -*- coding: utf-8 -*-

# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, You can
# obtain one at http://mozilla.org/MPL/2.0/.

from . import projects, login_identity, grants


def manage_resources(resources, externally_managed):
    """Set up the set of managed resources, specifically excluding resources that
    are externally managed, but including everything else."""
    assert externally_managed, "CAUTION: not tested with no externally-managed projects"

    em_bar = '|'.join(externally_managed)
    resources.manage(r"Role=(?!project:({}):).*".format(em_bar))
    resources.manage(r'WorkerPool=(?!proj-({})/).*'.format(em_bar))
    resources.manage(r'Client=(?!(github|static|project/({}))/).*'.format(em_bar))
    resources.manage(r'Hook=(?!project-({})/).*'.format(em_bar))


async def update_resources(resources):
    externally_managed = await projects.list_externally_managed_projects()
    manage_resources(resources, externally_managed)

    await projects.update_resources(resources)
    await login_identity.update_resources(resources)
    await grants.update_resources(resources)
