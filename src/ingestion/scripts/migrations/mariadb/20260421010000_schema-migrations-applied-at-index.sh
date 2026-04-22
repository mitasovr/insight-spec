#!/usr/bin/env bash
# Migration: add an index on schema_migrations(applied_at).
#
# Purpose:
#   Speed up "latest applied migration" queries -- `SELECT MAX(applied_at)`
#   or `ORDER BY applied_at DESC LIMIT 1` -- used by operators when
#   debugging apply order.
#
# This is also the first SH-style migration in the project. It doubles
# as a smoke test for the runner's `.sh` execution branch: the runner
# exports MARIADB_* env vars, invokes `bash file`, and records the
# version in `schema_migrations` on exit 0.
set -euo pipefail

# Pass the password via MYSQL_PWD rather than `-p...` so the process list
# and pod logs don't leak it, and so MariaDB doesn't print its standard
# "Using a password on the command line interface can be insecure"
# warning on every invocation.
kubectl -n "${MARIADB_NAMESPACE:?}" exec -i "${MARIADB_POD:?}" \
  -c "${MARIADB_CONTAINER:?}" -- \
  env MYSQL_PWD="${MARIADB_PASSWORD:?}" \
  mariadb -u "${MARIADB_USER:?}" -D "${MARIADB_DB:?}" --batch <<'SQL'
CREATE INDEX IF NOT EXISTS idx_schema_migrations_applied_at
    ON schema_migrations (applied_at);
SQL
