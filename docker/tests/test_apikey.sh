#!/bin/bash
set -e

echo "=== Test: API Key Authentication ==="

BASE_URL="${BASE_URL:-http://localhost:8040}"
COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
COOKIE_JAR=$(mktemp)
PASS_COUNT=0
FAIL_COUNT=0
ERROR_COUNT=0
API_KEY=""

cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

log() { echo "[info] $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $*"; }

get_xsrf_token() {
    curl -s -c "$COOKIE_JAR" -X GET "${BASE_URL}/login" > /dev/null 2>&1
    grep 'XSRF-TOKEN' "$COOKIE_JAR" 2>/dev/null | awk '{print $NF}' || echo ""
}

do_login() {
    local user="${1:-admin}" pass="${2:-admin123}"
    local token
    token=$(get_xsrf_token)
    [ -z "$token" ] && { echo ""; return 1; }
    curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -X POST "${BASE_URL}/login" \
        -H "Content-Type: application/json" \
        -H "X-XSRF-TOKEN: $token" \
        -d "{\"username\":\"$user\",\"password\":\"$pass\"}" 2>/dev/null || echo ""
}

get_session_xsrf_token() {
    grep 'XSRF-TOKEN' "$COOKIE_JAR" 2>/dev/null | awk '{print $NF}' || echo ""
}

generate_api_key_via_legacy() {
    local xsrf
    xsrf=$(get_session_xsrf_token)
    curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "X-XSRF-TOKEN: $xsrf" \
        "${BASE_URL}/legacy/index.php?module=Users&action=GenerateApiKey" 2>/dev/null || echo '{"api_key":""}'
}



call_v8_current_user() {
    local key="$1"
    curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $key" \
        --max-time 10 \
        "${BASE_URL}/Api/V8/current-user" 2>/dev/null || echo "000"
}

call_v8_current_user_body() {
    local key="$1"
    curl -s \
        -H "Authorization: Bearer $key" \
        --max-time 10 \
        "${BASE_URL}/Api/V8/current-user" 2>/dev/null || echo ""
}

# ============================================================
# SECTION 1: Admin API Key Generation (native auth)
# ============================================================
echo ""
echo "=== SECTION 1: Admin API Key Generation ==="

log "Logging in as admin..."
R=$(do_login "admin" "admin123")
echo "$R" | grep -q "login_success" && pass "Admin login succeeded" || {
    fail "Admin login succeeded"
    echo "    response: $R"
}

log "Generating API key..."
R=$(generate_api_key_via_legacy)
ADMIN_API_KEY=$(echo "$R" | python3 -c "
import sys, json, re
html = sys.stdin.read()
try:
    print(json.loads(html).get('api_key',''))
except:
    m = re.search(r'{\"api_key\":\"([^\"]+)\"}', html)
    if m: print(m.group(1))
" 2>/dev/null || echo "")
[ -n "$ADMIN_API_KEY" ] && [ ${#ADMIN_API_KEY} -eq 32 ] && pass "Admin API key generated (32 chars)" || {
    fail "Admin API key generated (got: $ADMIN_API_KEY)"
    echo "    response: $R"
}

# ============================================================
# SECTION 2: V8 API Authentication with Admin API Key
# ============================================================
echo ""
echo "=== SECTION 2: V8 API Auth (Admin) ==="

STATUS=$(call_v8_current_user "$ADMIN_API_KEY")
[ "$STATUS" = "200" ] && pass "V8 /current-user with admin API key returns 200" || {
    fail "V8 /current-user with admin API key (expected 200, got $STATUS)"
    BODY=$(call_v8_current_user_body "$ADMIN_API_KEY")
    echo "    body: $(echo "$BODY" | head -c 300)"
}

BODY=$(call_v8_current_user_body "$ADMIN_API_KEY")
echo "$BODY" | grep -qi "admin" && pass "V8 response contains admin user data" || {
    fail "V8 response contains admin user data"
    echo "    body: $(echo "$BODY" | head -c 300)"
}

# ============================================================
# SECTION 3: Invalid API Key Tests
# ============================================================
echo ""
echo "=== SECTION 3: Invalid API Key Tests ==="

STATUS=$(call_v8_current_user "invalidkey12345678901234567890")
[ "$STATUS" = "401" ] && pass "Invalid API key returns 401" || fail "Invalid API key (expected 401, got $STATUS)"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Authorization: Bearer " \
    "${BASE_URL}/Api/V8/current-user" 2>/dev/null || echo "000")
[ "$STATUS" = "401" ] && pass "Empty Bearer token returns 401" || fail "Empty Bearer token (expected 401, got $STATUS)"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Authorization: Basic $(echo -n 'admin:admin123' | base64)" \
    "${BASE_URL}/Api/V8/current-user" 2>/dev/null || echo "000")
[ "$STATUS" = "401" ] && pass "Basic auth (not Bearer) returns 401" || fail "Basic auth (expected 401, got $STATUS)"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "${BASE_URL}/Api/V8/current-user" 2>/dev/null || echo "000")
[ "$STATUS" = "401" ] && pass "No auth header returns 401" || fail "No auth header (expected 401, got $STATUS)"

# ============================================================
# SECTION 4: Key Regeneration
# ============================================================
echo ""
echo "=== SECTION 4: Key Regeneration ==="

log "Logging in as admin for regeneration test..."
R=$(do_login "admin" "admin123")

log "Generating new API key..."
R=$(generate_api_key_via_legacy)
NEW_API_KEY=$(echo "$R" | python3 -c "
import sys, json, re
html = sys.stdin.read()
try:
    print(json.loads(html).get('api_key',''))
except:
    m = re.search(r'{\"api_key\":\"([^\"]+)\"}', html)
    if m: print(m.group(1))
" 2>/dev/null || echo "")

sleep 1

log "Old key should fail (replaced by new key)..."
STATUS_OLD=$(call_v8_current_user "$ADMIN_API_KEY")
[ "$STATUS_OLD" = "401" ] && pass "Old key fails after regeneration" || {
    fail "Old key fails after regeneration (expected 401, got $STATUS_OLD)"
}

STATUS_NEW=$(call_v8_current_user "$NEW_API_KEY")
[ "$STATUS_NEW" = "200" ] && pass "New key works after regeneration" || {
    fail "New key works after regeneration (expected 200, got $STATUS_NEW)"
}

# Update ADMIN_API_KEY for potential further tests
ADMIN_API_KEY="$NEW_API_KEY"

# ============================================================
# SECTION 5: API Key Generation Endpoint - Symfony
# ============================================================
echo ""
echo "=== SECTION 5: Symfony API Key Generation ==="

log "Logging in as admin..."
R=$(do_login "admin" "admin123")

XSRF=$(get_session_xsrf_token)
SYMFONY_KEY_RESP=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -X POST "${BASE_URL}/api/key/generate" \
    -H "Content-Type: application/json" \
    -H "X-XSRF-TOKEN: $XSRF" 2>/dev/null || echo "")
SYMFONY_KEY=$(echo "$SYMFONY_KEY_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null || echo "")
[ -n "$SYMFONY_KEY" ] && [ ${#SYMFONY_KEY} -eq 32 ] && pass "Symfony API key generated (32 chars)" || {
    fail "Symfony API key generated"
    echo "    response: $SYMFONY_KEY_RESP"
}

# ============================================================
# SECTION 6: LDAP User Tests (if AUTH_TYPE is ldap)
# ============================================================
echo ""
echo "=== SECTION 6: LDAP User Tests ==="

AUTH_TYPE="${SUITECRM_AUTH_TYPE:-native}"
if [ "$AUTH_TYPE" = "ldap" ]; then
    log "Testing with LDAP user 'alloweduser'..."

    rm -f "$COOKIE_JAR"
    COOKIE_JAR=$(mktemp)

    R=$(do_login "alloweduser" "allowed123")
    echo "$R" | grep -q "login_success" && pass "LDAP alloweduser login succeeded" || {
        fail "LDAP alloweduser login"
        echo "    response: $R"
    }

    R=$(generate_api_key_via_legacy)
    LDAP_API_KEY=$(echo "$R" | python3 -c "
    import sys, json, re
    html = sys.stdin.read()
    try:
        print(json.loads(html).get('api_key',''))
    except:
        m = re.search(r'{\"api_key\":\"([^\"]+)\"}', html)
        if m: print(m.group(1))
    " 2>/dev/null || echo "")
    [ -n "$LDAP_API_KEY" ] && [ ${#LDAP_API_KEY} -eq 32 ] && pass "LDAP user API key generated" || fail "LDAP user API key generated"

    STATUS=$(call_v8_current_user "$LDAP_API_KEY")
    [ "$STATUS" = "200" ] && pass "V8 /current-user with LDAP user API key returns 200" || {
        fail "V8 /current-user with LDAP user API key (expected 200, got $STATUS)"
    }

    BODY=$(call_v8_current_user_body "$LDAP_API_KEY")
    echo "$BODY" | grep -qi "allowed" && pass "V8 response contains LDAP user data" || {
        fail "V8 response contains LDAP user data"
        echo "    body: $(echo "$BODY" | head -c 300)"
    }
else
    pass "Skipping LDAP tests (AUTH_TYPE=$AUTH_TYPE)"
fi

# ============================================================
# SECTION 7: UI Field Visibility (Legacy)
# ============================================================
echo ""
echo "=== SECTION 7: UI Field Visibility ==="

log "Logging in as admin for UI checks..."
rm -f "$COOKIE_JAR"
COOKIE_JAR=$(mktemp)
R=$(do_login "admin" "admin123")

log "Checking EditView for API key field..."
EDITVIEW=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    "${BASE_URL}/legacy/index.php?module=Users&action=EditView" 2>/dev/null || echo "")
echo "$EDITVIEW" | grep -q "api_key" && pass "EditView contains api_key field" || fail "EditView contains api_key field"
echo "$EDITVIEW" | grep -q "generate_api_key_btn" && pass "EditView has Generate button" || fail "EditView has Generate button"
echo "$EDITVIEW" | grep -q "copy_api_key_btn" && pass "EditView has Copy button" || fail "EditView has Copy button"

log "Checking DetailView metadata for API key field..."
docker compose exec -T app bash -c 'grep -q "api_key" /var/www/html/public/legacy/modules/Users/metadata/detailviewdefs.php' 2>/dev/null && pass "DetailView metadata contains api_key field" || fail "DetailView metadata contains api_key field"
docker compose exec -T app bash -c 'grep -q "copy_api_key_btn" /var/www/html/public/legacy/modules/Users/metadata/detailviewdefs.php' 2>/dev/null && pass "DetailView metadata has Copy button" || fail "DetailView metadata has Copy button"

# ============================================================
# SECTION 8: Symfony Endpoint Auth Requirements
# ============================================================
echo ""
echo "=== SECTION 8: Symfony Endpoint Auth Requirements ==="

log "Calling Symfony /api/key/generate without auth..."
UNAUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${BASE_URL}/api/key/generate" \
    -H "Content-Type: application/json" \
    --max-time 10 2>/dev/null || echo "000")
{ echo "$UNAUTH_STATUS" | grep -qE '^(401|403|307|302)$'; } && pass "Symfony endpoint blocks unauthenticated access (status=$UNAUTH_STATUS)" || {
    fail "Symfony endpoint blocks unauthenticated access (expected 4xx/3xx, got $UNAUTH_STATUS)"
}

log "Logging in as admin for Symfony endpoint test..."
rm -f "$COOKIE_JAR"
COOKIE_JAR=$(mktemp)
R=$(do_login "admin" "admin123")
XSRF=$(get_session_xsrf_token)

log "Calling Symfony /api/key/generate with valid session..."
AUTH_RESP=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -X POST "${BASE_URL}/api/key/generate" \
    -H "Content-Type: application/json" \
    -H "X-XSRF-TOKEN: $XSRF" \
    --max-time 10 2>/dev/null || echo "")
AUTH_KEY=$(echo "$AUTH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null || echo "")
[ -n "$AUTH_KEY" ] && [ ${#AUTH_KEY} -eq 32 ] && pass "Symfony endpoint returns key with valid session" || {
    fail "Symfony endpoint returns key with valid session"
    echo "    response: $AUTH_RESP"
}

# ============================================================
# SECTION 9: V8 API Module CRUD Operations
# ============================================================
echo ""
echo "=== SECTION 9: V8 API Module CRUD Operations ==="

log "Reusing session from Section 8 to generate API key..."
XSRF=$(get_session_xsrf_token)
KEY_RESP=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -X POST "${BASE_URL}/api/key/generate" \
    -H "Content-Type: application/json" \
    -H "X-XSRF-TOKEN: $XSRF" 2>/dev/null || echo "")
API_KEY=$(echo "$KEY_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null || echo "")

if [ -n "$API_KEY" ]; then

log "Listing Accounts (GET /Api/V8/module/Accounts)..."
ACCOUNTS_RESP=$(curl -s -H "Authorization: Bearer $API_KEY" \
    "${BASE_URL}/Api/V8/module/Accounts" \
    --max-time 10 2>/dev/null || echo "")
ACCOUNTS_STATUS=$(echo "$ACCOUNTS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if 'data' in d else 'no_data')" 2>/dev/null || echo "")
[ "$ACCOUNTS_STATUS" = "ok" ] && pass "List Accounts returns data" || {
    fail "List Accounts returns data"
    echo "    response: $(echo "$ACCOUNTS_RESP" | head -c 200)"
}

log "Listing Contacts (GET /Api/V8/module/Contacts)..."
CONTACTS_RESP=$(curl -s -H "Authorization: Bearer $API_KEY" \
    "${BASE_URL}/Api/V8/module/Contacts" \
    --max-time 10 2>/dev/null || echo "")
CONTACTS_STATUS=$(echo "$CONTACTS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if 'data' in d else 'no_data')" 2>/dev/null || echo "")
[ "$CONTACTS_STATUS" = "ok" ] && pass "List Contacts returns data" || {
    fail "List Contacts returns data"
    echo "    response: $(echo "$CONTACTS_RESP" | head -c 200)"
}

log "Listing Opportunities (GET /Api/V8/module/Opportunities)..."
OPPS_RESP=$(curl -s -H "Authorization: Bearer $API_KEY" \
    "${BASE_URL}/Api/V8/module/Opportunities" \
    --max-time 10 2>/dev/null || echo "")
OPPS_STATUS=$(echo "$OPPS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if 'data' in d else 'no_data')" 2>/dev/null || echo "")
[ "$OPPS_STATUS" = "ok" ] && pass "List Opportunities returns data" || {
    fail "List Opportunities returns data"
    echo "    response: $(echo "$OPPS_RESP" | head -c 200)"
}

log "Invalid module returns 400..."
INVALID_RESP=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_KEY" \
    "${BASE_URL}/Api/V8/module/NonExistentModule" \
    --max-time 10 2>/dev/null || echo "000")
[ "$INVALID_RESP" = "400" ] && pass "Invalid module returns 400" || fail "Invalid module returns 400 (expected 400, got $INVALID_RESP)"

else
    fail "Could not get API key for V8 tests"
fi

# ============================================================
# SECTION 10: Current User Identity Verification
# ============================================================
echo ""
echo "=== SECTION 10: Current User Identity Verification ==="

log "Logging in as admin for identity test..."
rm -f "$COOKIE_JAR"
COOKIE_JAR=$(mktemp)
R=$(do_login "admin" "admin123")

log "Generating admin API key..."
XSRF=$(get_session_xsrf_token)
ADMIN_KEY_RESP=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -X POST "${BASE_URL}/api/key/generate" \
    -H "Content-Type: application/json" \
    -H "X-XSRF-TOKEN: $XSRF" 2>/dev/null || echo "")
ADMIN_KEY=$(echo "$ADMIN_KEY_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null || echo "")

log "Calling /Api/V8/current-user with admin API key..."
ADMIN_USER_RESP=$(curl -s -H "Authorization: Bearer $ADMIN_KEY" \
    "${BASE_URL}/Api/V8/current-user" \
    --max-time 10 2>/dev/null || echo "")
ADMIN_USERNAME=$(echo "$ADMIN_USER_RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('data',{}).get('attributes',{}).get('user_name',''))
" 2>/dev/null || echo "")
[ "$ADMIN_USERNAME" = "admin" ] && pass "Admin API key identifies as user 'admin'" || {
    fail "Admin API key identifies as user 'admin' (got: '$ADMIN_USERNAME')"
    echo "    response: $(echo "$ADMIN_USER_RESP" | head -c 200)"
}

if [ "$AUTH_TYPE" = "ldap" ]; then
    log "Logging in as LDAP user 'alloweduser'..."
    rm -f "$COOKIE_JAR"
    COOKIE_JAR=$(mktemp)
    R=$(do_login "alloweduser" "allowed123")

    log "Generating LDAP user API key..."
    XSRF=$(get_session_xsrf_token)
    LDAP_KEY_RESP=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -X POST "${BASE_URL}/api/key/generate" \
        -H "Content-Type: application/json" \
        -H "X-XSRF-TOKEN: $XSRF" 2>/dev/null || echo "")
    LDAP_KEY=$(echo "$LDAP_KEY_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null || echo "")

    log "Calling /Api/V8/current-user with LDU user API key..."
    LDAP_USER_RESP=$(curl -s -H "Authorization: Bearer $LDAP_KEY" \
        "${BASE_URL}/Api/V8/current-user" \
        --max-time 10 2>/dev/null || echo "")
    LDAP_USERNAME=$(echo "$LDAP_USER_RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('data',{}).get('attributes',{}).get('user_name',''))
" 2>/dev/null || echo "")
    [ "$LDAP_USERNAME" = "alloweduser" ] && pass "LDAP user API key identifies as user 'alloweduser'" || {
        fail "LDAP user API key identifies as user 'alloweduser' (got: '$LDAP_USERNAME')"
        echo "    response: $(echo "$LDAP_USER_RESP" | head -c 200)"
    }
else
    pass "Skipping LDAP identity test (AUTH_TYPE=$AUTH_TYPE)"
fi

# ============================================================
# SECTION 11: EditView Input Field Value Persistence
# ============================================================
echo ""
echo "=== SECTION 11: EditView Input Field Value Persistence ==="

log "Logging in as admin for EditView value test..."
rm -f "$COOKIE_JAR"
COOKIE_JAR=$(mktemp)
R=$(do_login "admin" "admin123")

log "Generating a fresh API key..."
XSRF=$(get_session_xsrf_token)
KEY_RESP=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -X POST "${BASE_URL}/api/key/generate" \
    -H "Content-Type: application/json" \
    -H "X-XSRF-TOKEN: $XSRF" 2>/dev/null || echo "")
SAVED_KEY=$(echo "$KEY_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null || echo "")

log "Fetching EditView HTML..."
EDITVIEW_HTML=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    "${BASE_URL}/legacy/index.php?module=Users&action=EditView&record=1" \
    --max-time 10 2>/dev/null || echo "")

log "Extracting input field value..."
INPUT_VALUE=$(echo "$EDITVIEW_HTML" | python3 -c "
import sys, re
html = sys.stdin.read()
m = re.search(r'type=.text.*?id=.api_key.*?value=.([^\"]+)', html)
if m:
    print(m.group(1))
" 2>/dev/null || echo "")

[ "$INPUT_VALUE" = "$SAVED_KEY" ] && pass "EditView input field shows saved API key" || {
    fail "EditView input field shows saved API key"
    echo "    saved: $SAVED_KEY"
    echo "    input: $INPUT_VALUE"
}

# ============================================================
# RESULTS
# ============================================================
echo ""
echo "=========================================="
echo "  API KEY TEST RESULTS"
echo "=========================================="
echo "  PASSED:  $PASS_COUNT"
echo "  FAILED:  $FAIL_COUNT"
echo "  ERRORS:  $ERROR_COUNT"
echo "  TOTAL:   $((PASS_COUNT + FAIL_COUNT + ERROR_COUNT))"
echo "=========================================="

if [ "$FAIL_COUNT" -gt 0 ] || [ "$ERROR_COUNT" -gt 0 ]; then
    exit 1
fi
echo "All API key tests passed!"
exit 0
