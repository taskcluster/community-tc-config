# Defining projects

"Projects", as defined in <https://docs.taskcluster.net/docs/manual/using/namespaces#projects>

Each project is a distinct namespace within the deployment, with access to its own resources.
In particular, each project has its own workers. A project also has a set of administrators
defined by user roles.

Each file is defined as follows:

```yaml
<project-name>:
  adminRoles:
    # roles with administrative access to the project's resources
    - role1
    - ..

  # "externally managed" means that the resources in this project are managed outside
  # of this repository.  If this is false, then all project resources are managed by
  # this repo, and anything unrecognized will be deleted.  If this is true, then only
  # resources declared here will be managed.  If set to a regular expression or list
  # of regular expressions, then resources matching those regular expressions will be
  # ignored by this repository, but all others will be managed.
  externallyManaged: false

  repos:
    # repositories over which project admins have control; this is a prefix of a tc-github
    # repository roleId, so it should end in `:*` to select a specific repository, or `/*`
    # for an organization:
    - github.com/org/*
    - github.com/org/repo:*

  workerPools:
    <worker-pool-name>:
      owner: ..
      emailOnError: ..
      instanceTypes: a dict, where each key is an instance type, and the
          value is the capacity per instance for that instance type.
      imageset: top level key from imagesets.yml
      cloud: cloud to deploy in ('aws', 'azure', or 'gcp')
      ..: ..  # arguments to that function

      # For Azure worker pools, ARM template deployment via template specs is supported:
      armDeployment:  # Optional: Use ARM template-based deployment instead of image-based
        templateSpecId: /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Resources/templateSpecs/<name>/versions/<version>
        parameters:  # Optional: Custom parameters merged with auto-injected defaults
          customParam: customValue
          # Auto-injected parameters: vmSize, imageId, location, subnetId, priority
          # User-provided parameters override auto-injected ones
      armDeploymentResourceGroup: templates-rg  # Optional: Resource group for ARM deployment

  secrets:
    # Secrets associated with this project, suffixed to `project/<project-name>/`.
    # These secrets can be managed externally by setting the value to `true`:
    <name-suffix>: true
    # or can be given an explicit value, with interpolation of values from the
    # secret-values backend using `$<name>`:
    <name-suffix>:
      someservice:
        hostname: someservice.com
        username: $someservice-username
        password: $someservice-password

  hooks:
    # hooks, keyed by hookId.
    <hookId>:
      name:           # hook name, defaulting to hookId
      description:    # (optional)
      owner:          # (required) email of the owner
      emailOnError:   # (optional) if true, email the owner on firing errors
      schedule:       # (optional) list of cron schedules
      task:           # (required) task template
      triggerSchema:  # (optional) schema for trigger payloads

  clients:
    <clientId-suffix>:  # suffix after `project/<project-name>/`
      scopes: [ .. ]
      description: ..   # optional
    # when creating a client for a standalone worker, use `assume:worker-id:..` and `assume:worker-pool:..`.

  grants:  # (same format as grants.yml)
```

The worker-pool configurations are defined by Python functions, keyed by the `type` property.
See that file for the available options.  The defaults are usually fine.
