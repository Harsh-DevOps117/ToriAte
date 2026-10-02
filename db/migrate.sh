#!/bin/sh
set -eu
export PGHOST=postgres PGUSER=tori_app PGDATABASE=tori PGPASSWORD="$TORI_DB_PASSWORD"
until pg_isready -q; do sleep 1; done
psql -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS tori_meta;
CREATE TABLE IF NOT EXISTS tori_meta.migration (
  name text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now());
SQL
# versioned migrations first, then the repeatable ones (functions, views), so they see the final schema
for f in $(ls /migrations/*.sql | grep -v '\.repeatable\.sql$') /migrations/*.repeatable.sql; do
  name=$(basename "$f")
  sum=$(md5sum "$f" | cut -d' ' -f1)
  old=$(psql -tAq -c "SELECT checksum FROM tori_meta.migration WHERE name = '$name'")
  case "$name" in
    *.repeatable.sql) [ "$old" = "$sum" ] && continue ;;
    *) [ -n "$old" ] && continue ;;
  esac
  echo "applying $name"
  psql -q -v ON_ERROR_STOP=1 --single-transaction -f "$f"
  psql -q -c "INSERT INTO tori_meta.migration (name, checksum) VALUES ('$name', '$sum')
              ON CONFLICT (name) DO UPDATE SET checksum = EXCLUDED.checksum, applied_at = now()"
done
if [ "${SEED_DEV:-0}" = "1" ] && [ -f /seed/dev_seed.sql ]; then
  echo "applying dev seed"
  psql -q -v ON_ERROR_STOP=1 --single-transaction -f /seed/dev_seed.sql
fi
echo "migrations done"
