#!/bin/bash

echo "Starting SuiteCRM cron scheduler..."
cd /var/www/html

while true; do
  output=$(su -s /bin/sh www-data -c "cd /var/www/html && bin/console schedulers:run --no-interaction" 2>&1)
  exit_code=$?
  if [ $exit_code -eq 0 ] && ! echo "$output" | grep -q '(Failed)'; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Schedulers completed."
  else
    echo "$output" | awk "{ print strftime(\"[%Y-%m-%d %H:%M:%S]\"), \$0 }"
  fi
  sleep 60
done
