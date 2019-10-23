# Deployment Details

The Community-TC Taskcluster deployment has a number of service configuration settings that are not available in the API.
Most of those settings involve access credentials for various cloud providers and other external services, so they cannot be made public.
The following summarizes the non-secret parts of those settings for reference by those who do not have access to the secrets.

The cloudops team manages the service configuration.
Modifications to service configuration are handled via bugs filed in `Operations: Taskcluster Services` in the `Cloud Services` product on https://bugzilla.mozilla.org.

# Worker Manager Providers

## GCP

`community-tc-workers-google` is a google provider corresponding to GCP project `community-tc-workers`

## AWS

`community-tc-workers-aws` is an `aws` provider corresponding to AWS account `moz-fx-tc-community-workers`.
It has the following configuration:

```
region us-west-1:
 vpcId: vpc-0b4380783427d329a
 subnets by AZ:
  us-west-1a: subnet-0e43a99e9c865689e
  us-west-1b: subnet-0a5344f7003aede7c
 security groups:
  no-inbound: sg-00c4014bc978171d5
  docker-worker: sg-0d2ff88f36a05b499
region us-west-2:
 vpcId: vpc-0d9ea382d97dd57a3
 subnets by AZ:
  us-west-2a: subnet-048a61782df5ba378
  us-west-2b: subnet-05053e2898fc744e9
  us-west-2c: subnet-036a0812d241733ef
  us-west-2d: subnet-0fc336d9e5934c913
 security groups:
  no-inbound: sg-0659c2937ecbe7254
  docker-worker: sg-0f8a656368c567425
region us-east-1:
 vpcId: vpc-0691157d6095bd7ec
 subnets by AZ:
  us-east-1a: subnet-0ab0ba0d9836bb7ab
  us-east-1b: subnet-08c284e43fd180150
  us-east-1c: subnet-0034e6efd82d24939
  us-east-1d: subnet-05a055adc7a81adc0
  us-east-1e: subnet-03bbdcf0ec23f8caa
  us-east-1f: subnet-0cc340c5cf9346dcc
 security groups:
  no-inbound: sg-07f7d21a488e192c6
  docker-worker: sg-08fea1235cf66b102
region us-east-2:
 vpcId: vpc-0b1bc52c63637982f
 subnets by AZ:
  us-east-2a: subnet-05205c91d6a9f06e6
  us-east-2b: subnet-082be4d0d5e7e4d58
  us-east-2c: subnet-01eb0c6a5e15846db
 security groups:
  no-inbound: sg-00a9d64b3595c5088
  docker-worker: sg-0388de36e2f30ced2u
```

This configuration was generated with the script `misc/aws-worker-vpc-setup.sh` in this repository.

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
