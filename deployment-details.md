# Deployment Details

What follows are details about the Community-TC deployment.
Some of this information is useful for configuring resources in this repository, but lots of this information is handy for folks requesting changes to the deployment.

All of the information here can be modified via bugs filed in `Operations: Taskcluster Services` in the `Cloud Services` product on https://bugzilla.mozilla.org.

# Worker Manager Providers

* `community-tc-workers` is a google provider corresponding to GCP project `community-tc-workers` (NOTE: this will change to `community-tc-workers-google`)

# GitHub App

The GitHub app to connect your repositories to Taskcluster is is called `Community-TC Integration`, under the Taskcluster organization.
You can configure it at https://github.com/apps/community-tc-integration.

# Sign-In

Only GitHub logins are supported.
Signing In requires authenticating to the `Community-TC sign-in` app under the Taskcluster organization.

# Azure Tables

Azure tables are in the `communitytc` storage account in the "Firefox CI Production" directory.

# AWS (Storage)

TBD
