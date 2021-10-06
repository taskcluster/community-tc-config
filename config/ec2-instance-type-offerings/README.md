These files were generated with the script `/misc/update-instance-types.sh`.

Each json file represents a single AWS availability zone, and lists the
instance types that are availabile in that availability zone.

This is used when generating worker pool definitions, to ensure that a worker
pool does not include an availability zone/instance type combination that is
not supported.
