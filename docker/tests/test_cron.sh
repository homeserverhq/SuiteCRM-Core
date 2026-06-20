#!/bin/bash
set -e

echo "=== Test: Cron Scheduler ==="

# Check cron container is running
CRON_STATUS=$(docker inspect suitecrm-cron --format='{{.State.Status}}' 2>/dev/null || echo "not-found")
if [ "$CRON_STATUS" = "running" ]; then
  echo "PASS: Cron container is running"
else
  echo "FAIL: Cron container status is '${CRON_STATUS}'"
  exit 1
fi

# Check cron isn't restarting
CRON_RESTART_COUNT=$(docker inspect suitecrm-cron --format='{{.RestartCount}}' 2>/dev/null || echo "0")
if [ "$CRON_RESTART_COUNT" -lt 3 ]; then
  echo "PASS: Cron container restart count (${CRON_RESTART_COUNT}) is acceptable"
else
  echo "FAIL: Cron container restart count is ${CRON_RESTART_COUNT}"
  exit 1
fi

echo "=== Test: Cron - All checks passed ==="
