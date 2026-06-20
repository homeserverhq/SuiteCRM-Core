#!/bin/bash
set -e

# Shared config paths
CONFIG_DIR=/var/www/html/config
MARKER_FILE=$CONFIG_DIR/.installed
SHARED_CONFIG=$CONFIG_DIR/config.php

map_env() {
  local var_name="$1"
  local env_name="SUITECRM_${var_name}"
  if [ -n "${!env_name:-}" ]; then
    export "$var_name=${!env_name}"
  fi
}

map_env "SITE_URL"
map_env "APP_ENV"
map_env "APP_SECRET"
map_env "AUTH_TYPE"
map_env "TRUSTED_PROXIES"
map_env "TRUSTED_HOSTS"
map_env "MAILER_DSN"

if [ -n "${SUITECRM_VALKEY_DSN:-}" ]; then
  export VALKEY_DSN="${SUITECRM_VALKEY_DSN}"
fi

map_env "LDAP_HOST"
map_env "LDAP_PORT"
map_env "LDAP_ENCRYPTION"
map_env "LDAP_DN_STRING"
map_env "LDAP_QUERY_STRING"
map_env "LDAP_SEARCH_DN"
map_env "LDAP_SEARCH_PASSWORD"
map_env "LDAP_AUTO_CREATE"
map_env "LDAP_PROVIDER_BASE_DN"
map_env "LDAP_PROVIDER_SEARCH_DN"
map_env "LDAP_PROVIDER_SEARCH_PASSWORD"
map_env "LDAP_PROVIDER_UID_KEY"
map_env "LDAP_PROVIDER_FILTER"
map_env "LDAP_PROVIDER_DEFAULT_ROLES"
map_env "LDAP_GROUP_NAME"
map_env "LDAP_GROUP_ATTR"
map_env "LDAP_GROUP_OBJECTCLASS"
map_env "LDAP_GROUP_BASE_DN"
map_env "CORS_ALLOW_ORIGIN"
map_env "REFERER_HOST"
map_env "SKIP_WIZARD"
map_env "TZ"
map_env "SITE_NAME"

DB_USER="${SUITECRM_DB_USER:-suitecrm}"
DB_PASSWORD="${SUITECRM_DB_PASSWORD:-}"
DB_HOST="${SUITECRM_DB_HOST:-mariadb}"
DB_PORT="${SUITECRM_DB_PORT:-3306}"
DB_NAME="${SUITECRM_DB_NAME:-suitecrm}"

export DATABASE_URL="mysql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?serverVersion=10.11.2-MariaDB&charset=utf8mb4"

ADMIN_USERNAME="${SUITECRM_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${SUITECRM_ADMIN_PASSWORD:-admin123}"
ADMIN_FIRST_NAME="${SUITECRM_ADMIN_FIRST_NAME:-Admin}"
ADMIN_LAST_NAME="${SUITECRM_ADMIN_LAST_NAME:-Administrator}"
ADMIN_USER="${ADMIN_USERNAME}"
ADMIN_PASS="${ADMIN_PASSWORD}"
ADMIN_FIRST="${ADMIN_FIRST_NAME}"
ADMIN_LAST="${ADMIN_LAST_NAME}"
ADMIN_EMAIL="${SUITECRM_ADMIN_EMAIL_ADDRESS:-admin@example.com}"
SITE_NAME="${SUITECRM_SITE_NAME:-SuiteCRM}"

write_env_file() {
  local installed_secret="$1"
  cat <<EOF | run_as_www_data "cat > /var/www/html/.env.local"
APP_ENV=${APP_ENV:-prod}
APP_SECRET=${installed_secret:-${APP_SECRET:-}}
SITE_URL=${SITE_URL:-}
AUTH_TYPE=${AUTH_TYPE:-native}
DATABASE_URL=${DATABASE_URL}
CORS_ALLOW_ORIGIN=${CORS_ALLOW_ORIGIN:-'^https?://(localhost|127\.0\.0\.1)(:[0-9]+)?$'}
TRUSTED_PROXIES=${TRUSTED_PROXIES:-172.16.0.0/12}
MAILER_DSN=${MAILER_DSN:-}
VALKEY_DSN=${VALKEY_DSN:-}

# LDAP
LDAP_HOST=${LDAP_HOST:-}
LDAP_PORT=${LDAP_PORT:-389}
LDAP_ENCRYPTION=${LDAP_ENCRYPTION:-none}
LDAP_DN_STRING=${LDAP_DN_STRING:-}
LDAP_QUERY_STRING=${LDAP_QUERY_STRING:-}
LDAP_SEARCH_DN=${LDAP_SEARCH_DN:-}
LDAP_SEARCH_PASSWORD=${LDAP_SEARCH_PASSWORD:-}
LDAP_AUTO_CREATE=${LDAP_AUTO_CREATE:-disabled}
LDAP_PROVIDER_BASE_DN=${LDAP_PROVIDER_BASE_DN:-}
LDAP_PROVIDER_SEARCH_DN=${LDAP_PROVIDER_SEARCH_DN:-}
LDAP_PROVIDER_SEARCH_PASSWORD=${LDAP_PROVIDER_SEARCH_PASSWORD:-${LDAP_SEARCH_PASSWORD:-}}
LDAP_PROVIDER_UID_KEY=${LDAP_PROVIDER_UID_KEY:-uid}
LDAP_PROVIDER_FILTER=${LDAP_PROVIDER_FILTER:-}
LDAP_PROVIDER_DEFAULT_ROLES=${LDAP_PROVIDER_DEFAULT_ROLES:-ROLE_USER}
LDAP_GROUP_NAME=${LDAP_GROUP_NAME:-primaryusers}
LDAP_GROUP_ATTR=${LDAP_GROUP_ATTR:-uniqueMember}
LDAP_GROUP_OBJECTCLASS=${LDAP_GROUP_OBJECTCLASS:-groupOfUniqueNames}
LDAP_GROUP_BASE_DN=${LDAP_GROUP_BASE_DN:-ou=groups,dc=example,dc=com}

# Referer hosts for legacy XSRF check (comma-separated)
REFERER_HOST=${REFERER_HOST:-}
EOF
}

fix_permissions() {
  local dirs="/var/www/html/cache /var/www/html/logs /var/www/html/tmp /var/www/html/public/legacy/upload /var/www/html/public/legacy/custom /var/www/html/public/legacy/cache /var/www/html/public/media /var/www/html/extensions /var/www/html/Api /var/www/html/var /var/www/html/config /var/www/html/public"
  chown www-data:www-data /var/www/html
  local d
  for d in $dirs; do
    [ -e "$d" ] && chown -R www-data:www-data "$d" 2>/dev/null || true
    # [ -e "$d" ] && chmod -R u+rwX,g+rwX,o+rX "$d" 2>/dev/null || true
  done
  # chmod 640 /var/www/html/Api/V8/OAuth2/private.key 2>/dev/null || true
}

run_as_www_data() {
  su -s /bin/sh www-data -c "$*"
}

COMMAND="${1:-php-fpm}"
case "$COMMAND" in
  cron|worker)
    echo "${COMMAND} container detected. Waiting for requirements..."
    write_env_file ""

    echo "Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
    while ! mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" --skip-ssl --silent 2>/dev/null; do
      sleep 1
    done
    echo "MariaDB is ready."

    echo "Waiting for installation to complete..."
    while [ ! -f "$MARKER_FILE" ]; do
      sleep 2
    done
    echo "Installation detected."

    if [ ! -f /var/www/html/public/legacy/config.php ] && [ -f "$SHARED_CONFIG" ]; then
      cp "$SHARED_CONFIG" /var/www/html/public/legacy/config.php
    fi

    echo "Clearing cache..."
    run_as_www_data "cd /var/www/html && php bin/console cache:clear" 2>/dev/null || true
    run_as_www_data "cd /var/www/html && php bin/console cache:warmup" 2>&1 || true

    echo "Starting ${COMMAND}..."
    exec "/usr/local/bin/${COMMAND}.sh"
    ;;
esac

# ====== EARLY PERMISSIONS CHECK ======
echo "Early permissions check..."
fix_permissions

write_env_file ""

echo "Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
while ! mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" --skip-ssl --silent 2>/dev/null; do
  sleep 1
done
echo "MariaDB is ready."

INSTALLED=false
if [ -f "$MARKER_FILE" ] || [ -f /var/www/html/public/legacy/config.php ]; then
  INSTALLED=true
fi

if [ "$INSTALLED" = false ]; then
  echo "SuiteCRM not detected. Running silent install..."

  SITE_URL="${SITE_URL:-http://localhost:8040}"

  run_as_www_data "cat > /var/www/html/public/legacy/config_si.php" <<PHPEOF
<?php
\$sugar_config_si = array (
  'dbUSRData' => 'same',
  'default_currency_iso4217' => 'USD',
  'default_currency_name' => 'US Dollar',
  'default_currency_significant_digits' => '2',
  'default_currency_symbol' => '\$',
  'default_date_format' => 'Y-m-d',
  'default_decimal_seperator' => '.',
  'default_export_charset' => 'ISO-8859-1',
  'default_language' => 'en_us',
  'default_locale_name_format' => 's f l',
  'default_number_grouping_seperator' => ',',
  'default_time_format' => 'H:i',
  'export_delimiter' => ',',
  'setup_db_admin_password' => '${DB_PASSWORD}',
  'setup_db_admin_user_name' => '${DB_USER}',
  'setup_db_port_num' => '${DB_PORT}',
  'setup_db_create_database' => 0,
  'setup_db_database_name' => '${DB_NAME}',
  'setup_db_drop_tables' => 0,
  'setup_db_host_name' => '${DB_HOST}',
  'demoData' => 'no',
  'setup_db_type' => 'mysql',
  'setup_db_username_is_privileged' => true,
  'setup_site_admin_password' => '${ADMIN_PASS}',
  'setup_site_admin_user_name' => '${ADMIN_USER}',
  'setup_site_url' => '${SITE_URL}',
  'setup_system_name' => '${SITE_NAME}',
);
PHPEOF

  echo "Running suitecrm:app:install..."
  set +e
  run_as_www_data "cd /var/www/html && php bin/console suitecrm:app:install \
    --no-interaction \
    --sys_check_option=true \
    --db_host=\"${DB_HOST}\" \
    --db_username=\"${DB_USER}\" \
    --db_password=\"${DB_PASSWORD}\" \
    --db_name=\"${DB_NAME}\" \
    --db_port=\"${DB_PORT}\" \
    --site_host=\"${SITE_URL}\" \
    --site_username=\"${ADMIN_USER}\" \
    --site_password=\"${ADMIN_PASS}\" \
    --demoData=no" 2>&1 | grep -vE '(root has been added|REMOVE_THIS_NOTICE|However, if you really|_REMOVE_THIS_NOTICE_IF_YOU_REALLY_WANT_TO_ALLOW_ROOT)'
  INSTALL_EXIT=${PIPESTATUS[0]}
  set -e
  if [ $INSTALL_EXIT -ne 0 ]; then
    echo "ERROR: Install failed with exit code $INSTALL_EXIT"
    exit 1
  fi
  echo "Install completed."

  if [ -n "${VALKEY_DSN:-}" ]; then
    echo "Enabling Valkey cache..."
    run_as_www_data "mkdir -p /var/www/html/config/packages && cat > /var/www/html/config/packages/cache.yaml" <<YAMLEOF
framework:
  cache:
    app: cache.adapter.redis
    system: cache.adapter.redis
    default_redis_provider: '%env(VALKEY_DSN)%'
YAMLEOF
  fi

  if [ -f /var/www/html/public/legacy/config.php ]; then
    sed -i 's/root_REMOVE_THIS_NOTICE_IF_YOU_REALLY_WANT_TO_ALLOW_ROOT/root/g' /var/www/html/public/legacy/config.php
    cp /var/www/html/public/legacy/config.php "$SHARED_CONFIG"
  fi

  touch "$MARKER_FILE"

  echo "Clearing cache..."
  run_as_www_data "cd /var/www/html && php bin/console cache:clear" 2>/dev/null || true
  run_as_www_data "cd /var/www/html && php bin/console cache:warmup" 2>&1 || true

  echo "Installation complete."
else
  echo "SuiteCRM already installed."

  if [ ! -f /var/www/html/public/legacy/config.php ]; then
    if [ -f "$SHARED_CONFIG" ]; then
      cp "$SHARED_CONFIG" /var/www/html/public/legacy/config.php
    fi
  fi

  echo "Running doctrine migrations..."
  cd /var/www/html
  run_as_www_data "cd /var/www/html && php bin/console doctrine:migrations:migrate --no-interaction" 2>&1 | grep -v -E 'already exists|SQLSTATE\[42S01\]' || true

  echo "Clearing cache..."
  run_as_www_data "cd /var/www/html && php bin/console cache:clear" 2>/dev/null || true
  run_as_www_data "cd /var/www/html && php bin/console cache:warmup" 2>&1 || true
fi

echo "Ensuring .env.local has all required env vars..."
INSTALLED_SECRET="$(grep '^APP_SECRET=' /var/www/html/.env.local 2>/dev/null | head -1 | cut -d= -f2-)"
write_env_file "$INSTALLED_SECRET"
echo ".env.local updated."

if [ -f /var/www/html/public/legacy/config.php ]; then
  cp /var/www/html/public/legacy/config.php "$SHARED_CONFIG" 2>/dev/null || true
  chmod 644 "$SHARED_CONFIG" 2>/dev/null || true
fi

# Flush Valkey cache at startup to clear stale rate limiter data
if [ -n "${VALKEY_DSN:-}" ]; then
  valkey-cli -u "${VALKEY_DSN}" FLUSHALL 2>/dev/null || true
fi

# Generate OAuth2 keys if missing and OAUTH2 env vars not set (eliminates CryptKey fatal error)
if [ -z "${OAUTH2_PRIVATE_KEY:-}" ] && [ ! -f /var/www/html/public/legacy/Api/V8/OAuth2/private.key ]; then
  mkdir -p /var/www/html/public/legacy/Api/V8/OAuth2
  openssl genrsa -out /var/www/html/public/legacy/Api/V8/OAuth2/private.key 2048 2>/dev/null
  openssl rsa -in /var/www/html/public/legacy/Api/V8/OAuth2/private.key -pubout -out /var/www/html/public/legacy/Api/V8/OAuth2/public.key 2>/dev/null
  chmod 640 /var/www/html/public/legacy/Api/V8/OAuth2/private.key
  echo "OAuth2 keys generated."
fi
# Invalidate stale legacy vardefs cache (field defs changed between builds)
if [ -d /var/www/html/public/legacy/cache/modules ]; then
  find /var/www/html/public/legacy/cache/modules -name '*vardefs*' -delete 2>/dev/null || true
fi

# ====== POST-OAUTH PERMISSIONS CHECK ======
echo "Post-OAuth permissions check..."
fix_permissions

# Write config_override.php with referer hosts from SUITECRM_REFERER_HOST
CONFIG_OVERRIDE=/var/www/html/public/legacy/config_override.php
if [ -n "${REFERER_HOST:-}" ]; then
  IFS=',' read -ra HOSTS <<< "$REFERER_HOST"
  {
    echo "<?php"
    echo "// Added by docker-entrypoint.sh from SUITECRM_REFERER_HOST"
    for host in "${HOSTS[@]}"; do
      host=$(echo "$host" | xargs)
      [ -n "$host" ] && echo "\$sugar_config['http_referer']['list'][] = '$host';"
    done
  } | run_as_www_data "cat > /var/www/html/public/legacy/config_override.php"
  chmod 644 "$CONFIG_OVERRIDE"
  echo "config_override.php written with referer hosts."
fi

# Write env sync PHP to temp file for clean su www-data execution
cat > /tmp/env_sync.php << 'PHPEOF'
<?php
$dsn = "mysql:host=" . getenv("DB_HOST") . ";dbname=" . getenv("DB_NAME");
$pdo = new PDO($dsn, getenv("DB_USER"), getenv("DB_PASSWORD"));

// Admin credentials (SuiteCRM LegacyPasswordHasher: bcrypt(md5(password)))
$hash = password_hash(strtolower(md5(getenv("ADMIN_PASSWORD"))), PASSWORD_DEFAULT);
$stmt = $pdo->prepare("UPDATE users SET user_name = ?, first_name = ?, last_name = ?, user_hash = ? WHERE id = ? AND deleted = 0");
$stmt->execute([getenv("ADMIN_USERNAME"), getenv("ADMIN_FIRST_NAME"), getenv("ADMIN_LAST_NAME"), $hash, "1"]);
echo "  Admin credentials synchronized.\n";

// Admin email address
$email = getenv("ADMIN_EMAIL");
$emailCaps = strtoupper($email);
$eaStmt = $pdo->prepare("SELECT id FROM email_addresses WHERE email_address_caps = ? AND deleted = 0");
$eaStmt->execute([$emailCaps]);
$eaRow = $eaStmt->fetch(PDO::FETCH_ASSOC);
if ($eaRow) {
  $eaId = $eaRow["id"];
} else {
  $eaId = $pdo->query("SELECT UUID()")->fetchColumn();
  $insStmt = $pdo->prepare("INSERT INTO email_addresses (id, email_address, email_address_caps, invalid_email, opt_out, date_created, date_modified, deleted) VALUES (?, ?, ?, 0, 0, NOW(), NOW(), 0)");
  $insStmt->execute([$eaId, $email, $emailCaps]);
}
$pdo->prepare("UPDATE email_addr_bean_rel SET deleted = 1 WHERE bean_id = '1' AND bean_module = 'Users' AND deleted = 0")->execute();
$relId = $pdo->query("SELECT UUID()")->fetchColumn();
$relStmt = $pdo->prepare("INSERT INTO email_addr_bean_rel (id, bean_id, bean_module, email_address_id, primary_address, reply_to_address, date_created, date_modified, deleted) VALUES (?, '1', 'Users', ?, 1, 0, NOW(), NOW(), 0)");
$relStmt->execute([$relId, $eaId]);
echo "  Admin email set to $email.\n";

// Company name
$pdo->exec("DELETE FROM config WHERE category = \"system\" AND name = \"name\"");
$stmt = $pdo->prepare("INSERT INTO config (category, name, value) VALUES (?, ?, ?)");
$stmt->execute(["system", "name", getenv("SITE_NAME")]);
echo "  Company name updated.\n";

// Skip onboarding wizard
if (getenv("SKIP_WIZARD") === "true") {
  $pdo->exec("INSERT INTO user_preferences (id, assigned_user_id, category, contents, date_entered, date_modified, deleted) SELECT UUID(), u.id, \"global\", \"YToxOntzOjI6InV0IjtzOjE6IjEiO30=\", NOW(), NOW(), 0 FROM users u WHERE u.deleted = 0 AND NOT EXISTS (SELECT 1 FROM user_preferences up WHERE up.assigned_user_id = u.id AND up.category = \"global\" AND up.deleted = 0)");
  echo "  Wizard skipped for all users.\n";
}

if (getenv("TZ")) {
  $tz = getenv("TZ");
  $stmt = $pdo->query("SELECT id, contents FROM user_preferences WHERE category = \"global\" AND deleted = 0");
  while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
    $contents = unserialize(base64_decode($row["contents"]));
    if (($contents["timezone"] ?? "") !== $tz) {
      $contents["timezone"] = $tz;
      $updateStmt = $pdo->prepare("UPDATE user_preferences SET contents = ?, date_modified = NOW() WHERE id = ?");
      $updateStmt->execute([base64_encode(serialize($contents)), $row["id"]]);
    }
  }
  echo "  Timezone set to $tz for all users.\n";
}
PHPEOF

# Sync env vars to SuiteCRM config (admin credentials, company name, wizard skip)
echo "Syncing env vars to SuiteCRM config..."
export DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD
export ADMIN_USERNAME ADMIN_PASSWORD ADMIN_FIRST_NAME ADMIN_LAST_NAME ADMIN_EMAIL SITE_NAME SKIP_WIZARD TZ
run_as_www_data "php /tmp/env_sync.php" 2>&1 || echo "  (env sync skipped - first install or DB not ready)"
rm -f /tmp/env_sync.php
echo "Env sync complete."

# ====== FINAL PERMISSIONS SWEEP ======
echo "Final permissions sweep..."
fix_permissions
echo "All permissions checks complete. Starting service..."

case "${1:-php-fpm}" in
  php-fpm)
    shift
    exec php-fpm "$@"
    ;;
  nginx)
    shift
    exec nginx "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
