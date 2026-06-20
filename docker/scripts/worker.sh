#!/bin/bash
set -e

echo "Starting SuiteCRM messenger worker..."
cd /var/www/html

exec su -s /bin/sh www-data -c "cd /var/www/html && bin/console messenger:consume internal-async --no-interaction --time-limit=3600" 2>&1 | \
  awk "{ print strftime(\"[%Y-%m-%d %H:%M:%S]\"), \$0 }"
