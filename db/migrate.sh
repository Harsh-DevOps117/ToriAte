#!/bin/sh
# Applies db/migrations/*.sql in order, once each (tracked in tori_meta.migration).
# Files named *.repeatable.sql are re-applied whenever their content changes (functions, views).
set -eu
export PGHOST=postgres PGUSER=tori_app PGDATABASE=tori PGPASSWORD="$TORI_DB_PASSWORD"
until pg_isready -q; do sleep 1; done
psql -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS tori_meta;
CREATE TABLE IF NOT EXISTS tori_meta.migration (
  name text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now());
SQL
for f in /migrations/*.sql; do
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
