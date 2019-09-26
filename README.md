# community-tc-config

This repository defines the runtime configuration (roles, hooks, worker pools, etc.) for the Taskcluster deployment at https://community-tc.services.mozilla.com/.
It uses [tc-admin](https://github.com/taskcluster/tc-admin) to examine and update the deployment.
See that tool's documentation for background on how the process works.

## Quick Start

Install this app by running `pip install -e .` in this directory.

After making a change the the configuration, you can examine the results with

```
TASKCLUSTER_ROOT_URL=https://community-tc.services.mozilla.com/. tc-admin diff
```

To apply the configuration, you will need to have a client with suffucient scopes set up in `TASKCLUSTER_CLIENT_ID` and `TASKCLUSTER_ACCESS_TOKEN`.
Then, run

```
TASKCLUSTER_ROOT_URL=https://community-tc.services.mozilla.com/. tc-admin apply
```

Typically a member of the Taskcluster team will do the latter for you once a PR has been merged.

## Deployment Details

Unsure about what `providerId` to use?
Wondering which GitHub app to install on your repo?
All of that information is available [here](deployment-details.md).
