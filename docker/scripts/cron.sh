#!/bin/bash
set -e

echo "Starting SuiteCRM cron scheduler..."
cd /var/www/html

while true; do
  su -s /bin/sh www-data -c "cd /var/www/html && bin/console schedulers:run --no-interaction" 2>&1 | \
    awk "{ print strftime(\"[%Y-%m-%d %H:%M:%S]\"), \$0 }"
  sleep 60
done
