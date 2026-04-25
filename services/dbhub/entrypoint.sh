#!/bin/sh
# When DSN is empty, fall back to --demo (bundled sample SQLite database)
# so the service starts cleanly out of the box. Setting DSN via
# `harbor env dbhub DSN ...` switches to the configured database.
set -e

cd /app

if [ -z "${DSN}" ]; then
  set -- --demo "$@"
fi

exec node dist/index.js "$@"
