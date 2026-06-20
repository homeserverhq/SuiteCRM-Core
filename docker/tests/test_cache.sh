#!/bin/bash
set -e

echo "=== Test: Valkey Cache ==="

# Check Valkey container is running
VALKEY_STATUS=$(docker inspect suitecrm-valkey --format='{{.State.Status}}' 2>/dev/null || echo "not-found")
if [ "$VALKEY_STATUS" = "running" ]; then
  echo "PASS: Valkey container is running"
else
  echo "FAIL: Valkey container status is '${VALKEY_STATUS}'"
  exit 1
fi

# Try to PING Valkey
VALKEY_PING=$(docker exec suitecrm-valkey valkey-cli ping 2>/dev/null || echo "error")
if [ "$VALKEY_PING" = "PONG" ]; then
  echo "PASS: Valkey responds to PING"
else
  echo "FAIL: Valkey not responding. Got: ${VALKEY_PING}"
  exit 1
fi

echo "=== Test: Cache - All checks passed ==="
