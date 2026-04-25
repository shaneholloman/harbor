#!/bin/sh
# Pre-create /workspace/work as the host user. Docker creates missing
# bind-mount targets as root:root by default, and the upstream unsloth
# entrypoint then `chmod -R 777`s them — leaving the host directory
# undeletable without `sudo`. By chowning here before the main container
# starts, host ownership survives the upstream chmod.
#
# Also pre-creates /studio_auth (the bind-mount target for Studio's auth
# directory) and chowns it to the in-container `unsloth` user (uid=1001),
# which Studio runs as. Without this, Studio fails to create auth.db and
# the bootstrap sidecar has no first-run creds to scrape.
set -e

if [ -n "${HARBOR_USER_ID}" ] && [ -n "${HARBOR_GROUP_ID}" ]; then
  chown -R "${HARBOR_USER_ID}:${HARBOR_GROUP_ID}" /workspace/work 2>/dev/null || true
fi

# Studio's container `unsloth` user is uid=1001:gid=1001 (baked into the
# upstream image; not configurable). Mirror that owner on the bind mount,
# but keep the dir traversable by the host group so the user can `ls` /
# wipe it from the host without `sudo`. Studio applies its own 0600 perms
# to auth.db inside the dir.
if [ -d /studio_auth ]; then
  chown -R "1001:${HARBOR_GROUP_ID:-1001}" /studio_auth 2>/dev/null || true
  chmod 0775 /studio_auth 2>/dev/null || true
fi
