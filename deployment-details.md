# Deployment Details

The Community-TC Taskcluster deployment has a number of service configuration settings that are not available in the API.
Most of those settings involve access credentials for various cloud providers and other external services, so they cannot be made public.
The following summarizes the non-secret parts of those settings for reference by those who do not have access to the secrets.

The cloudops team manages the service configuration.
Modifications to service configuration are handled via bugs filed in `Operations: Taskcluster Services` in the `Cloud Services` product on https://bugzilla.mozilla.org.

# Worker Manager Providers

* `community-tc-workers` is a google provider corresponding to GCP project `community-tc-workers` (NOTE: this will change to `community-tc-workers-google`)

# GitHub App

The GitHub app for the `taskcluster-github` service is called `Community-TC Integration`, under the Taskcluster organization.
Its public URL is https://github.com/apps/community-tc-integration.

# Sign-In

Only GitHub logins are supported.
Signing In requires authenticating to the `Community-TC sign-in` app under the Taskcluster organization.

# Azure Tables

Azure tables are in the `communitytc` storage account in the "Firefox CI Production" directory.

# AWS (Storage)

Artifacts are stored in buckets in the `cloudops-taskcluster-aws-prod` account.
