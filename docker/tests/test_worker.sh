#!/bin/bash
set -e

echo "=== Test: Messenger Worker ==="

# Check worker container is running
WORKER_STATUS=$(docker inspect suitecrm-worker --format='{{.State.Status}}' 2>/dev/null || echo "not-found")
if [ "$WORKER_STATUS" = "running" ]; then
  echo "PASS: Worker container is running"
else
  echo "FAIL: Worker container status is '${WORKER_STATUS}'"
  exit 1
fi

# Check worker isn't restarting
WORKER_RESTART_COUNT=$(docker inspect suitecrm-worker --format='{{.RestartCount}}' 2>/dev/null || echo "0")
if [ "$WORKER_RESTART_COUNT" -lt 3 ]; then
  echo "PASS: Worker container restart count (${WORKER_RESTART_COUNT}) is acceptable"
else
  echo "FAIL: Worker container restart count is ${WORKER_RESTART_COUNT}"
  exit 1
fi

echo "=== Test: Worker - All checks passed ==="
