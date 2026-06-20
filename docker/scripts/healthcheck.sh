#!/bin/bash
set -e

# Health check for the app container
# Returns 0 if healthy, 1 if not

# Check PHP-FPM is running
if ! pgrep php-fpm > /dev/null; then
  echo "PHP-FPM is not running"
  exit 1
fi

# Check the app responds via local fastcgi
SCRIPT_NAME=/index.php SCRIPT_FILENAME=/var/www/html/public/index.php \
  REQUEST_METHOD=GET \
  cgi-fcgi -bind -connect 127.0.0.1:9000 2>/dev/null | head -1 | grep -q "200 OK"

exit $?
