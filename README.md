# community-tc-config

This repository defines a tool to manage the runtime configuration for the Taskcluster deployment at https://community-tc.services.mozilla.com/.
It uses [tc-admin](https://github.com/taskcluster/tc-admin) to examine and update the deployment.
See that library's documentation for background on how the process works.

## Background

A Taskcluster deployment has a collection of resources such a [roles](https://community-tc.services.mozilla.com/docs/manual/design/apis/hawk/roles), [hooks](https://community-tc.services.mozilla.com/docs/reference/core/hooks), and [worker pools](https://community-tc.services.mozilla.com/docs/reference/core/worker-manager), that define its behavior.
These can all be managed via the Taskcluster API, but managing them by hand is error-prone and difficult to track over time.
This tool exists to manage those resources in a controlled, observable way.
It does so by making API calls to determine the current state, examining this repository to determine the desired state, and then "applying" the necessary changes to get from the former to the latter.

A deployment is also defined by a number of back-end settings that are not available in the API.
These are defined by the [service configuration](https://community-tc.services.mozilla.com/docs/manual/deploying).
While this tool cannot change those settings, it does depend on them, and they are described [here](deployment-details.md).

## Quick Start

If you would like to propose a change to the configuration of the Community-TC deployment, you are in the right spot.
You should already have an understanding of the resources you would like to modify.
See the [Taskcluster Documentation](https://community-tc.services.mozilla.com/docs) or consult with the Taskcluster team -- we are responsible for managing this deployment, and happy to help -- if you need assistance.

Begin by installing this app by running `pip install -e .` in this directory.
Then, run

```
TASKCLUSTER_ROOT_URL=https://community-tc.services.mozilla.com tc-admin diff
```

This will show you the current difference between what's defined in your local repository and the runtime configuration of the deployment.
Most of the time, there should be no difference.

Then, change the configuration in this repository, using the comments in the relevant files as a guide (@petemoore: these don't exist yet, TBD).
After making a change the the configuration, you can examine the results by running `tc-admin diff` again.
If you are adding or removing a number of resources, you can use `--ids-only` to show only the names of the added or removed resources.
See `tc-admin --help` for more useful command-line tricks.
