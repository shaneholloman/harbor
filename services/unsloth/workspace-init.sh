#!/bin/sh
# Pre-create /workspace/work as the host user. Docker creates missing
# bind-mount targets as root:root by default, and the upstream unsloth
# entrypoint then `chmod -R 777`s them — leaving the host directory
# undeletable without `sudo`. By chowning here before the main container
# starts, host ownership survives the upstream chmod.
set -e

if [ -n "${HARBOR_USER_ID}" ] && [ -n "${HARBOR_GROUP_ID}" ]; then
  chown -R "${HARBOR_USER_ID}:${HARBOR_GROUP_ID}" /workspace/work 2>/dev/null || true
fi
