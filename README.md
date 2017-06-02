# clean_registry.sh

This script purges old, "untagged" repositories and runs the garbage collector in Docker Registry >= 2.4.0.  It works on the whole registry or the specified repositories.

The optional flag -x may be used to completely remove the specified repositories or tagged images.

NOTE: This script stops the Registry container during the purge, making it temporarily unavailable to clients.

Usage:

clean_registry.sh [--dry-run] [-x] REGISTRY_CONTAINER [REPOSITORY[:TAG]]...
