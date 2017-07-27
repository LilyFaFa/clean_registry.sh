# clean_registry.sh

This script purges old, "untagged" repositories and runs the garbage collector in Docker Registry >= 2.4.0.  It works on the whole registry or the specified repositories.

The optional flag -x may be used to completely remove the specified repositories or tagged images.

NOTES:

  - This script stops the Registry container during cleanup, making it temporarily unavailable to clients.
  - This script assumes local storage (the **filesystem** storage driver described at:
  https://docs.docker.com/registry/configuration/#storage

Usage:

clean_registry.sh [--dry-run] [-x] REGISTRY_CONTAINER [REPOSITORY[:TAG]]...

## UPDATE:

Better use the dockerized app [ricardobranco/clean_registry](https://hub.docker.com/r/ricardobranco/clean_registry/)
