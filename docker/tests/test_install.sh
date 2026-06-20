#!/bin/bash
set -e

echo "=== Test: SuiteCRM Installation ==="
echo "Checking HTTP endpoints..."

BASE_URL="${BASE_URL:-http://localhost:8040}"

# Check main page
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
  echo "PASS: ${BASE_URL}/ returned ${HTTP_CODE}"
else
  echo "FAIL: ${BASE_URL}/ returned ${HTTP_CODE} (expected 200 or 302)"
  exit 1
fi

# Check login page
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/login" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "401" ]; then
  echo "PASS: ${BASE_URL}/login returned ${HTTP_CODE}"
else
  echo "FAIL: ${BASE_URL}/login returned ${HTTP_CODE} (expected 200, 302, or 401)"
  exit 1
fi

# Check API
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
  echo "PASS: ${BASE_URL}/api returned ${HTTP_CODE}"
else
  echo "FAIL: ${BASE_URL}/api returned ${HTTP_CODE} (expected 200, 401, or 403)"
  exit 1
fi

echo "=== Test: Install - All checks passed ==="
