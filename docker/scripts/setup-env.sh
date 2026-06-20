#!/bin/bash
set -e

wait_for_db() {
  local host="${SUITECRM_DB_HOST:-mariadb}"
  local port="${SUITECRM_DB_PORT:-3306}"
  echo "Waiting for MariaDB at ${host}:${port}..."
  while ! mysqladmin ping -h"${host}" -P"${port}" --skip-ssl --silent 2>/dev/null; do
    sleep 1
  done
  echo "MariaDB is ready."
}

if [ ! -f /var/www/html/.env.local ]; then
  DB_USER="${SUITECRM_DB_USER:-suitecrm}"
  DB_PASSWORD="${SUITECRM_DB_PASSWORD:-}"
  DB_HOST="${SUITECRM_DB_HOST:-mariadb}"
  DB_PORT="${SUITECRM_DB_PORT:-3306}"
  DB_NAME="${SUITECRM_DB_NAME:-suitecrm}"
  DATABASE_URL="mysql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?serverVersion=10.11.2-MariaDB&charset=utf8mb4"

  cat > /var/www/html/.env.local <<EOF
APP_ENV=${SUITECRM_APP_ENV:-prod}
APP_SECRET=${SUITECRM_APP_SECRET:-}
DATABASE_URL=${DATABASE_URL}
VALKEY_DSN=${SUITECRM_VALKEY_DSN:-redis://valkey:6379/0}
EOF
  echo "Created .env.local for cron/worker."
fi

wait_for_db
