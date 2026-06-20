#!/bin/bash
set -e

echo "=== Test: LDAP Authentication ==="

BASE_URL="${BASE_URL:-http://localhost:8040}"
AUTH_TYPE="${SUITECRM_AUTH_TYPE:-native}"
COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

if [ "$AUTH_TYPE" != "ldap" ]; then
  echo "SKIP: AUTH_TYPE is '${AUTH_TYPE}', not 'ldap'. Skipping LDAP tests."
  exit 0
fi

get_xsrf_token() {
    curl -s -c "$COOKIE_JAR" -X GET "${BASE_URL}/login" > /dev/null 2>&1
    grep 'XSRF-TOKEN' "$COOKIE_JAR" 2>/dev/null | awk '{print $NF}' || echo ""
}

do_login() {
    local user="$1" pass="$2"
    local token
    token=$(get_xsrf_token)
    [ -z "$token" ] && { echo ""; return 1; }
    curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -X POST "${BASE_URL}/login" \
        -H "Content-Type: application/json" \
        -H "X-XSRF-TOKEN: $token" \
        -d "{\"username\":\"$user\",\"password\":\"$pass\"}" 2>/dev/null || echo ""
}

# Login as admin (native auth - should always work)
echo "Testing admin login (native auth)..."
R=$(do_login "admin" "admin123")
if echo "$R" | grep -q "login_success"; then
  echo "PASS: Admin login succeeded"
else
  echo "FAIL: Admin login failed. Response: $R"
  exit 1
fi

rm -f "$COOKIE_JAR"
COOKIE_JAR=$(mktemp)

# Login as allowed LDAP user
echo "Testing alloweduser login (LDAP - should succeed)..."
R=$(do_login "alloweduser" "allowed123")
if echo "$R" | grep -q "login_success"; then
  echo "PASS: alloweduser login succeeded (member of primaryusers)"
else
  echo "FAIL: alloweduser login failed. Response: $R"
  exit 1
fi

rm -f "$COOKIE_JAR"
COOKIE_JAR=$(mktemp)

# Login as denied LDAP user
echo "Testing denieduser login (LDAP - should fail)..."
R=$(do_login "denieduser" "denied123")
if echo "$R" | grep -q "Invalid\|error\|missing"; then
  echo "PASS: denieduser login failed (not a member of primaryusers)"
else
  echo "FAIL: denieduser login unexpectedly succeeded. Response: $R"
  exit 1
fi

echo "=== Test: LDAP - All checks passed ==="
