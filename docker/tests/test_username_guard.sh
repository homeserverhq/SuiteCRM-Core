#!/bin/bash
set -e

echo "=== Test: Username Change Guard ==="

BASE_URL="${BASE_URL:-http://localhost:8040}"
COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

# Step 1: Get XSRF token from login page
TOKEN=$(curl -s -c "$COOKIE_JAR" -X GET "${BASE_URL}/login" 2>/dev/null | grep -o 'XSRF-TOKEN' || true)
TOKEN=$(grep 'XSRF-TOKEN' "$COOKIE_JAR" 2>/dev/null | awk '{print $NF}')
if [ -z "$TOKEN" ]; then
  echo "FAIL: Could not get XSRF token"
  exit 1
fi
echo "PASS: Got XSRF token"

# Step 2: Login as admin via /login with X-XSRF-TOKEN header
ADMIN_RESPONSE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -X POST "${BASE_URL}/login" \
  -H "Content-Type: application/json" \
  -H "X-XSRF-TOKEN: ${TOKEN}" \
  -d '{"username":"admin","password":"admin123"}' 2>/dev/null)

if echo "$ADMIN_RESPONSE" | grep -q "login_success"; then
  echo "PASS: Admin login succeeded"
else
  echo "FAIL: Admin login failed. Response: $ADMIN_RESPONSE"
  exit 1
fi

# Step 3: Get current admin user info from API
echo "Getting current admin user info..."
USER_RESPONSE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -H "Accept: application/json" \
  "${BASE_URL}/api/record/1" 2>/dev/null || echo "{}")

CURRENT_USERNAME=$(echo "$USER_RESPONSE" | grep -o '"userName":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
echo "Current username: ${CURRENT_USERNAME}"

# Step 4: Try to save user via legacy endpoint with changed username
echo "Attempting to change username via legacy save..."
LEGACY_RESPONSE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -X POST "${BASE_URL}/legacy/index.php" \
  -d "module=Users&action=Save&record=1&user_name=hackedadmin&name=admin&is_admin=1" 2>/dev/null || echo "")

# Step 5: Verify username wasn't changed by checking API again
echo "Verifying username after save attempt..."
VERIFY_RESPONSE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -H "Accept: application/json" \
  "${BASE_URL}/api/record/1" 2>/dev/null || echo "{}")

VERIFY_USERNAME=$(echo "$VERIFY_RESPONSE" | grep -o '"userName":"[^"]*"' | cut -d'"' -f4 || echo "")

if [ "$VERIFY_USERNAME" = "$CURRENT_USERNAME" ]; then
  echo "PASS: Username remains '${VERIFY_USERNAME}' (unchanged)"
elif [ "$VERIFY_USERNAME" = "admin" ]; then
  echo "PASS: Username remains unchanged after save attempt"
else
  echo "FAIL: Username changed to '${VERIFY_USERNAME}' (expected '${CURRENT_USERNAME}' or 'admin')"
  exit 1
fi

echo "=== Test: Username Guard - All checks passed ==="
