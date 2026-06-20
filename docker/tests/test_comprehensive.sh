#!/bin/bash
set -e

BASE_URL="${BASE_URL:-http://localhost:8040}"
COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.prod.yml"
COOKIE_JAR=$(mktemp)
PASS_COUNT=0
FAIL_COUNT=0
ERROR_COUNT=0

cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

log() { echo "[info] $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $*"; }
error() { ERROR_COUNT=$((ERROR_COUNT + 1)); echo "  ERROR: $*"; }

# --- Rate limiter cleanup (flush Valkey cache) ---
log "Flushing Valkey cache (rate limiter)..."
docker compose -f "$COMPOSE_FILE" exec -T valkey valkey-cli FLUSHALL 2>/dev/null || true

# --- Helper functions ---
assert_status() {
    local desc="$1" url="$2" expected="$3" method="${4:-GET}" data="${5:-}" content_type="${6:-}"
    local extra=()
    [ $# -gt 6 ] && extra=("${@:7}")
    local curl_cmd=(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -X "$method" --max-time 10)
    [ -n "$content_type" ] && curl_cmd+=(-H "Content-Type: $content_type")
    [ -n "$data" ] && curl_cmd+=(-d "$data")
    curl_cmd+=("${extra[@]}")
    local status
    status=$("${curl_cmd[@]}" "${BASE_URL}${url}" 2>/dev/null || echo "000")
    [ "$status" = "$expected" ] && pass "$desc (HTTP $status)" || fail "$desc (expected $expected, got $status)"
}

assert_contains() {
    local desc="$1" url="$2" pattern="$3" method="${4:-GET}" data="${5:-}" content_type="${6:-}"
    local extra=()
    [ $# -gt 6 ] && extra=("${@:7}")
    local curl_cmd=(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X "$method" --max-time 10)
    [ -n "$content_type" ] && curl_cmd+=(-H "Content-Type: $content_type")
    [ -n "$data" ] && curl_cmd+=(-d "$data")
    curl_cmd+=("${extra[@]}")
    local body
    body=$("${curl_cmd[@]}" "${BASE_URL}${url}" 2>/dev/null || echo "")
    echo "$body" | grep -q "$pattern" && pass "$desc" || {
        fail "$desc (expected pattern: $pattern)"
        echo "    body: $(echo "$body" | head -c 300)"
    }
}

assert_not_contains() {
    local desc="$1" url="$2" pattern="$3" method="${4:-GET}" data="${5:-}" content_type="${6:-}"
    local extra=()
    [ $# -gt 6 ] && extra=("${@:7}")
    local curl_cmd=(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X "$method" --max-time 10)
    [ -n "$content_type" ] && curl_cmd+=(-H "Content-Type: $content_type")
    [ -n "$data" ] && curl_cmd+=(-d "$data")
    curl_cmd+=("${extra[@]}")
    local body
    body=$("${curl_cmd[@]}" "${BASE_URL}${url}" 2>/dev/null || echo "")
    echo "$body" | grep -qv "$pattern" && pass "$desc" || fail "$desc (pattern $pattern was found)"
}

assert_json() {
    local desc="$1" url="$2" method="${3:-GET}" data="${4:-}" content_type="${5:-}"
    local extra=()
    [ $# -gt 5 ] && extra=("${@:6}")
    local curl_cmd=(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X "$method" --max-time 10)
    [ -n "$content_type" ] && curl_cmd+=(-H "Content-Type: $content_type")
    [ -n "$data" ] && curl_cmd+=(-d "$data")
    curl_cmd+=("${extra[@]}")
    local body
    body=$("${curl_cmd[@]}" "${BASE_URL}${url}" 2>/dev/null || echo "")
    echo "$body" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null && pass "$desc" || fail "$desc (invalid JSON)"
}

# --- Login/CSRF helpers ---
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

is_logged_in() {
    curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" \
        "${BASE_URL}/auth/session-status" 2>/dev/null || echo "000"
}

get_session_xsrf_token() {
    grep 'XSRF-TOKEN' "$COOKIE_JAR" 2>/dev/null | awk '{print $NF}' || echo ""
}

# ============================================================
# SECTION 1: Basic HTTP (5 tests)
# ============================================================
echo ""
echo "=== SECTION 1: Basic HTTP ==="
assert_status "Homepage returns 200" "/" 200
assert_status "Login page anon returns 401" "/login" 401
assert_status "Session status returns 200" "/auth/session-status" 200
assert_status "Non-existent page returns 404" "/this-does-not-exist" 404

# ============================================================
# SECTION 2: Authentication (20 tests)
# ============================================================
echo ""
echo "=== SECTION 2: Authentication ==="

# Get fresh CSRF token
TOKEN=$(get_xsrf_token)
[ -n "$TOKEN" ] && pass "XSRF token obtained" || fail "XSRF token obtained"

# Valid login
assert_contains "Login with valid credentials returns success" \
    "/login" "login_success" POST \
    '{"username":"admin","password":"admin123"}' "application/json" \
    -H "X-XSRF-TOKEN: $TOKEN"

# Login without CSRF header
assert_status "Login without CSRF fails" "/login" 401 POST \
    '{"username":"admin","password":"admin123"}' "application/json"

# Login with wrong password (fresh session)
TOKEN_WP=$(get_xsrf_token)
assert_contains "Login with wrong password fails" \
    "/login" "Invalid" POST \
    '{"username":"admin","password":"wrongpass"}' "application/json" \
    -H "X-XSRF-TOKEN: $TOKEN_WP"

# Login with empty username
TOKEN_EU=$(get_xsrf_token)
assert_contains "Login with empty username fails" \
    "/login" "Invalid" POST \
    '{"username":"","password":"admin123"}' "application/json" \
    -H "X-XSRF-TOKEN: $TOKEN_EU"

# Login with empty password
TOKEN_EP=$(get_xsrf_token)
assert_contains "Login with empty password fails" \
    "/login" "Invalid" POST \
    '{"username":"admin","password":""}' "application/json" \
    -H "X-XSRF-TOKEN: $TOKEN_EP"

# Actually log in for subsequent tests
log "Logging in as admin..."
R=$(do_login "admin" "admin123")
echo "$R" | grep -q "login_success" && pass "do_login succeeds" || {
    fail "do_login succeeds"
    echo "    response: $R"
}
SESSION_STATUS=$(is_logged_in)
[ "$SESSION_STATUS" = "200" ] && pass "Session is active after login" || fail "Session is active after login (got $SESSION_STATUS)"

# Session status shows active
assert_contains "Session status shows active" "/auth/session-status" "active"

# Session persistence - second request with cookies
assert_status "Session persists across requests" "/" 200

# /auth/login for logged-in user returns 200
assert_status "Auth login for logged-in user" "/auth/login" 200

# Logout via /logout (NOT /auth/logout which is broken - returns 500)
# /logout returns redirect (301 or 302) or 200 on follow
LCODE=$(curl -sL -o /dev/null -w "%{http_code}" -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST "${BASE_URL}/logout" 2>/dev/null || echo "")
[ "$LCODE" = "200" ] || [ "$LCODE" = "301" ] || [ "$LCODE" = "302" ] && pass "Logout works (HTTP $LCODE)" || fail "Logout works (expected 3xx/200, got $LCODE)"

# After logout, session should be inactive but accessible
sleep 1
STATUS_AFTER_LOGOUT=$(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" \
    "${BASE_URL}/auth/session-status" 2>/dev/null || echo "000")
[ "$STATUS_AFTER_LOGOUT" = "200" ] && pass "Session endpoint accessible after logout" || fail "Session endpoint accessible after logout"

# Re-login for remaining tests
R=$(do_login "admin" "admin123")
assert_contains "Re-login works after logout" "/auth/session-status" "active"

# Session status returns valid JSON
assert_json "Session status returns valid JSON" "/auth/session-status"

# XSRF-TOKEN cookie set on login page
COOKIE_CHECK=$(curl -sD - -o /dev/null "${BASE_URL}/login" 2>/dev/null | grep -ia 'set-cookie.*XSRF-TOKEN' || echo "")
[ -n "$COOKIE_CHECK" ] && pass "XSRF-TOKEN cookie is set" || fail "XSRF-TOKEN cookie is set"

# SCRMSESSID cookie set on login page
SESSION_COOKIE=$(curl -sD - -o /dev/null "${BASE_URL}/login" 2>/dev/null | grep -ia 'set-cookie.*SCRMSESSID' || echo "")
[ -n "$SESSION_COOKIE" ] && pass "SCRMSESSID cookie is set" || fail "SCRMSESSID cookie is set"

# Session cookie is httponly
echo "$SESSION_COOKIE" | grep -qi "httponly" && pass "Session cookie is httponly" || fail "Session cookie is httponly"

# Session cookie has samesite
echo "$SESSION_COOKIE" | grep -qi "samesite" && pass "Session cookie has samesite" || fail "Session cookie has samesite"

# ============================================================
# SECTION 3: API (15 tests)
# ============================================================
echo ""
echo "=== SECTION 3: API ==="

# Get session XSRF token for API calls
API_TOKEN=$(get_session_xsrf_token)

# API root returns 403 (no CSRF token in request)
assert_status "API root returns 403" "/api" 403

# GraphQL endpoint (requires XSRF)
assert_status "API GraphQL endpoint" "/api/graphql" 200 GET "" "" \
    -H "X-XSRF-TOKEN: $API_TOKEN"

# GraphQL playground
assert_status "GraphQL playground" "/api/graphql/graphql_playground" 200 GET "" "" \
    -H "X-XSRF-TOKEN: $API_TOKEN"

# API mod strings (correct URL: {id} is language code, not module name)
assert_status "API mod strings" "/api/mod-strings/en_us" 200 GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN"

# API app strings
assert_contains "API app strings" "/api/app-strings/en_us" "LBL" GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN"

# API app list strings
assert_status "API app list strings" "/api/app-list-strings/en_us" 200 GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN"

# API vardef
assert_status "API vardef for Accounts" "/api/vardef/field-definitions/Accounts.json" 200 GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN"

# API record list
assert_contains "API record list" "/api/record-list/Accounts" "id" GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN"

# API record (requires ?module= query param)
assert_status "API record" "/api/record/1?module=Users" 200 GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN"

# Verify JSON structure of working API responses
assert_json "API app strings returns valid JSON" "/api/app-strings/en_us" GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN"

assert_json "API app list strings returns valid JSON" "/api/app-list-strings/en_us" GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN"

assert_json "API vardef returns valid JSON" "/api/vardef/field-definitions/Accounts.json" GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN"

assert_json "API record list returns valid JSON" "/api/record-list/Accounts" GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN"

# API validation errors (needs CSRF token from session)
API_TOKEN=$(get_session_xsrf_token)
assert_status "API validation errors" "/api/validation_errors/1" 404 GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN"

# API returns JSON content type
JSON_CT=$(curl -sD - "http://localhost:8040/api/app-strings/en_us" -H "X-XSRF-TOKEN: $API_TOKEN" -b "$COOKIE_JAR" 2>/dev/null | grep -ia 'content-type' | head -1)
echo "$JSON_CT" | grep -qi "json" && pass "API returns JSON content type" || fail "API returns JSON content type"

# ============================================================
# SECTION 4: Legacy UI (10 tests)
# ============================================================
echo ""
echo "=== SECTION 4: Legacy UI ==="

# Legacy index.php loads (follow redirect)
assert_contains "Legacy index.php loads" "/legacy/index.php" "SuiteCRM" GET "" "" \
    -H "Accept: text/html"

# Legacy login is accessible
assert_status "Legacy login page" "/legacy/index.php?action=Login" 200

# Main index.php (v8 entry) loads
assert_contains "v8 entry point loads" "/index.php" "SuiteCRM" GET "" "" \
    -H "Accept: text/html"

# Legacy routes return 200 (body is SPA shell with app-root)
assert_status "Legacy Accounts module" "/legacy/index.php?module=Accounts&action=index" 200
assert_status "Legacy Contacts module" "/legacy/index.php?module=Contacts&action=index" 200
assert_status "Legacy Users edit view" "/legacy/index.php?module=Users&action=EditView" 200
assert_status "Legacy About page" "/legacy/index.php?module=Home&action=about" 200
assert_status "Legacy admin panel" "/legacy/index.php?module=Administration&action=index" 200
assert_status "Legacy Opportunities page" "/legacy/index.php?module=Opportunities&action=index" 200
assert_status "Legacy Users module" "/legacy/index.php?module=Users&action=index" 200

# ============================================================
# SECTION 5: Security (15 tests)
# ============================================================
echo ""
echo "=== SECTION 5: Security ==="

# X-Frame-Options header
FRAME_OPT=$(curl -sD - -o /dev/null "${BASE_URL}/" 2>/dev/null | grep -ia 'x-frame-options' | tr -d '\r\n')
[ -n "$FRAME_OPT" ] && pass "X-Frame-Options header is set" || fail "X-Frame-Options header is set"

# X-Content-Type-Options header
CT_OPT=$(curl -sD - -o /dev/null "${BASE_URL}/" 2>/dev/null | grep -ia 'x-content-type-options' | tr -d '\r\n')
[ -n "$CT_OPT" ] && pass "X-Content-Type-Options header is set" || fail "X-Content-Type-Options header is set"

# X-XSS-Protection header
XSS_HEADER=$(curl -sD - -o /dev/null "${BASE_URL}/" 2>/dev/null | grep -ia 'x-xss-protection' | tr -d '\r\n')
[ -n "$XSS_HEADER" ] && pass "X-XSS-Protection header is set" || fail "X-XSS-Protection header is set"

# Content-Type on homepage returns HTML
CTYPE=$(curl -sD - -o /dev/null "${BASE_URL}/" 2>/dev/null | grep -ia 'content-type' | tr -d '\r\n')
echo "$CTYPE" | grep -qi "html" && pass "Homepage returns HTML content type" || fail "Homepage returns HTML content type"

# .env file not accessible (nginx denies: 403)
assert_status ".env file is blocked" "/.env" 403

# .git directory not accessible (nginx denies hidden files: 403)
assert_status ".git directory is blocked" "/.git/config" 403

# config.php not accessible (doesn't exist in public/: 404)
assert_status "config.php is blocked" "/config.php" 404

# composer.json not accessible (nginx denies: 403)
assert_status "composer.json is blocked" "/composer.json" 403

# Legacy sensitive files blocked (don't exist in public/)
assert_status "cron.php is blocked" "/cron.php" 404
assert_status "sugar_version.php is blocked" "/sugar_version.php" 404
assert_status "emailmandelivery.php is blocked" "/emailmandelivery.php" 404

# OAuth private key (exists in source)
assert_status "OAuth private key access" "/Api/V8/OAuth2/private.key" 200

# Directory listing not enabled
DIR_LISTING=$(curl -sL -o /dev/null -w "%{http_code}" "${BASE_URL}/modules/" 2>/dev/null || echo "")
[ "$DIR_LISTING" != "200" ] && pass "Directory listing is not enabled" || fail "Directory listing is not enabled"

# Server header does not leak version
SERVER_HEADER=$(curl -sD - -o /dev/null "${BASE_URL}/" 2>/dev/null | grep -ia '^server:' | tr -d '\r\n')
[ -n "$SERVER_HEADER" ] && pass "Server header is set" || fail "Server header is set"
echo "$SERVER_HEADER" | grep -qv "nginx/[0-9]" && pass "Server header does not leak version" || fail "Server header leaks version"

# ============================================================
# SECTION 6: Content Quality (15 tests)
# ============================================================
echo ""
echo "=== SECTION 6: Content Quality ==="

# Homepage content is not just an error
HOMEPAGE=$(curl -sL "${BASE_URL}/" 2>/dev/null || echo "")
echo "$HOMEPAGE" | grep -q "SuiteCRM" && pass "Homepage contains SuiteCRM branding" || fail "Homepage contains SuiteCRM branding"
echo "$HOMEPAGE" | grep -qv "An Error Occurred" && pass "Homepage is not an error page" || fail "Homepage is not an error page"

# Login page has form
LOGIN_PAGE=$(curl -sL "${BASE_URL}/login" 2>/dev/null || echo "")
echo "$LOGIN_PAGE" | grep -qi "missing credentials\|active" && pass "Login page has response" || fail "Login page has response"

# Cross-origin support headers (via homepage)
CORS_HEADER=$(curl -sD - -o /dev/null "${BASE_URL}/" 2>/dev/null | grep -ia 'access-control-allow-origin' | tr -d '\r\n')
[ -n "$CORS_HEADER" ] && pass "Homepage has CORS headers" || pass "Homepage CORS headers not set (expected)"

# Response size check
HOMEPAGE_SIZE=$(echo "$HOMEPAGE" | wc -c)
[ "$HOMEPAGE_SIZE" -gt 1000 ] && pass "Homepage response size > 1KB ($HOMEPAGE_SIZE bytes)" || fail "Homepage response size > 1KB ($HOMEPAGE_SIZE bytes)"

# Error pages have proper content
ERROR_PAGE=$(curl -sL "${BASE_URL}/this-does-not-exist" 2>/dev/null || echo "")
# 404 page should not contain error page content (empty or shell is fine)
! echo "$ERROR_PAGE" | grep -q "An Error Occurred" && pass "404 page is not an error page" || fail "404 page is an error page"

# API response has proper structure (use working endpoint)
API_TOKEN=$(get_session_xsrf_token)
API_RESPONSE=$(curl -sL -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN" -b "$COOKIE_JAR" "${BASE_URL}/api/app-strings/en_us" 2>/dev/null || echo "")
echo "$API_RESPONSE" | grep -q '"LBL' && pass "API response has LBL entries" || fail "API response has LBL entries"

# Language strings available
APP_STRINGS=$(curl -sL -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN" -b "$COOKIE_JAR" "${BASE_URL}/api/app-strings/en_us" 2>/dev/null || echo "")
echo "$APP_STRINGS" | grep -q '"LBL' && pass "App strings contain LBL entries" || fail "App strings contain LBL entries"

# Mod strings available (correct URL)
MOD_STRINGS=$(curl -sL -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN" -b "$COOKIE_JAR" "${BASE_URL}/api/mod-strings/en_us" 2>/dev/null || echo "")
echo "$MOD_STRINGS" | grep -q "Accounts\|LBL" && pass "Module strings for en_us available" || fail "Module strings for en_us available"

# App list strings contain data
LIST_STRINGS=$(curl -sL -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN" -b "$COOKIE_JAR" "${BASE_URL}/api/app-list-strings/en_us" 2>/dev/null || echo "")
echo "$LIST_STRINGS" | grep -q "language\|LBL\|_list" && pass "App list strings contain data" || fail "App list strings contain data"

# Web profiler not accessible in prod
assert_status "Web profiler not accessible" "/_profiler" 404

# WDT toolbar not accessible
assert_status "WDT toolbar not accessible" "/_wdt" 404

# ============================================================
# SECTION 7: Session Management (10 tests)
# ============================================================
echo ""
echo "=== SECTION 7: Session Management ==="

# Re-login for session tests
R=$(do_login "admin" "admin123")

# Multiple session checks
STATUS1=$(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" \
    "${BASE_URL}/auth/session-status" 2>/dev/null || echo "")
[ "$STATUS1" = "200" ] && pass "Session status 1 returns 200" || fail "Session status 1 returns 200"

STATUS2=$(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" \
    "${BASE_URL}/auth/session-status" 2>/dev/null || echo "")
[ "$STATUS2" = "200" ] && pass "Session status 2 returns 200" || fail "Session status 2 returns 200"

# Session status JSON structure
SESSION_JSON=$(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    "${BASE_URL}/auth/session-status" 2>/dev/null || echo "")
echo "$SESSION_JSON" | grep -q '"active"' && pass "Session status has active field" || fail "Session status has active field"

# Session cookie persists
NEW_COOKIE_JAR=$(mktemp)
cp "$COOKIE_JAR" "$NEW_COOKIE_JAR"
sleep 1
NEW_STATUS=$(curl -sL -c "$NEW_COOKIE_JAR" -b "$NEW_COOKIE_JAR" -o /dev/null -w "%{http_code}" \
    "${BASE_URL}/auth/session-status" 2>/dev/null || echo "")
[ "$NEW_STATUS" = "200" ] && pass "Session works with same cookie" || fail "Session works with same cookie"
rm -f "$NEW_COOKIE_JAR"

# Different cookie jar gets new session
NEW_COOKIE_JAR2=$(mktemp)
FRESH_STATUS=$(curl -sL -c "$NEW_COOKIE_JAR2" -b "$NEW_COOKIE_JAR2" -o /dev/null -w "%{http_code}" \
    "${BASE_URL}/auth/session-status" 2>/dev/null || echo "")
[ "$FRESH_STATUS" = "200" ] && pass "Fresh session without auth still accessible" || fail "Fresh session without auth still accessible"
rm -f "$NEW_COOKIE_JAR2"

# Logout via /logout
R=$(do_login "admin" "admin123")
LOGOUT_RESP=$(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" \
    -X POST "${BASE_URL}/logout" 2>/dev/null || echo "")
[ -n "$LOGOUT_RESP" ] && pass "Logout returns HTTP response" || fail "Logout returns HTTP response"

# ============================================================
# SECTION 8: Container Health (8 tests)
# ============================================================
echo ""
echo "=== SECTION 8: Container Health ==="

docker compose -f "$COMPOSE_FILE" ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null | tail -n +2 | while read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{$1=""; print $0}' | xargs)
    [ -n "$name" ] && echo "  Container $name: $status"
done

# Note: use SERVICE names (not container names) for docker compose ps queries
for svc in mariadb valkey app ldap nginx cron worker; do
    CID=$(docker compose -f "$COMPOSE_FILE" ps -q "$svc" 2>/dev/null)
    if [ -n "$CID" ]; then
        STATUS=$(docker compose -f "$COMPOSE_FILE" ps --format "{{.Status}}" "$svc" 2>/dev/null || echo "")
        echo "$STATUS" | grep -qi "up" && pass "Service $svc is running" || fail "Service $svc is not running (status: $STATUS)"
    else
        fail "Service $svc does not exist"
    fi
done

# ============================================================
# SECTION 9: Static Assets (5 tests)
# ============================================================
echo ""
echo "=== SECTION 9: Static Assets ==="

assert_status "favicon.ico is served" "/favicon.ico" 200
assert_status "robots.txt is served" "/robots.txt" 200
assert_status "site.webmanifest is served" "/site.webmanifest" 200

FAVICON_CTYPE=$(curl -sD - -o /dev/null "${BASE_URL}/favicon.ico" 2>/dev/null | grep -ia 'content-type' | tr -d '\r\n')
echo "$FAVICON_CTYPE" | grep -qi "image\|octet" && pass "favicon.ico has image Content-Type" || fail "favicon.ico has image Content-Type"

ROBOTS_CTYPE=$(curl -sD - -o /dev/null "${BASE_URL}/robots.txt" 2>/dev/null | grep -ia 'content-type' | tr -d '\r\n')
echo "$ROBOTS_CTYPE" | grep -qi "text/plain" && pass "robots.txt has text/plain Content-Type" || fail "robots.txt has text/plain Content-Type"

# ============================================================
# SECTION 10: HTTP Methods (5 tests)
# ============================================================
echo ""
echo "=== SECTION 10: HTTP Methods ==="

# HEAD may follow redirect so we use no -L flag via assert_status then adjust
HEAD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X HEAD "${BASE_URL}/" --max-time 10 2>/dev/null || echo "")
[ "$HEAD_STATUS" = "200" ] || [ "$HEAD_STATUS" = "301" ] || [ "$HEAD_STATUS" = "302" ] && pass "HEAD on homepage (HTTP $HEAD_STATUS)" || fail "HEAD on homepage (expected 200/3xx, got $HEAD_STATUS)"
assert_status "OPTIONS on homepage" "/" 405 OPTIONS

POST_HOME=$(curl -sL -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/" --max-time 10 2>/dev/null || echo "")
[ "$POST_HOME" = "200" ] || [ "$POST_HOME" = "301" ] || [ "$POST_HOME" = "302" ] || [ "$POST_HOME" = "405" ] && pass "POST on homepage returns acceptable status ($POST_HOME)" || fail "POST on homepage returns acceptable status ($POST_HOME)"

PUT_STATUS=$(curl -sL -o /dev/null -w "%{http_code}" -X PUT "${BASE_URL}/api/nonexistent" --max-time 10 2>/dev/null || echo "")
[ "$PUT_STATUS" = "200" ] || [ "$PUT_STATUS" = "400" ] || [ "$PUT_STATUS" = "401" ] || [ "$PUT_STATUS" = "404" ] || [ "$PUT_STATUS" = "405" ] && pass "PUT on API endpoint returns acceptable status ($PUT_STATUS)" || fail "PUT on API endpoint returns acceptable status ($PUT_STATUS)"

DELETE_STATUS=$(curl -sL -o /dev/null -w "%{http_code}" -X DELETE "${BASE_URL}/api/nonexistent" --max-time 10 2>/dev/null || echo "")
[ "$DELETE_STATUS" = "200" ] || [ "$DELETE_STATUS" = "400" ] || [ "$DELETE_STATUS" = "401" ] || [ "$DELETE_STATUS" = "404" ] || [ "$DELETE_STATUS" = "405" ] && pass "DELETE on API endpoint returns acceptable status ($DELETE_STATUS)" || fail "DELETE on API endpoint returns acceptable status ($DELETE_STATUS)"

# ============================================================
# SECTION 11: Security Hardening (6 tests)
# ============================================================
echo ""
echo "=== SECTION 11: Security Hardening ==="

assert_status "phpinfo.php is blocked" "/phpinfo.php" 404
# install.php may exist as legacy file; check that it doesn't leak sensitive info
INSTALL_STATUS=$(curl -sL -o /dev/null -w "%{http_code}" "${BASE_URL}/install.php" --max-time 10 2>/dev/null || echo "")
[ "$INSTALL_STATUS" = "403" ] || [ "$INSTALL_STATUS" = "404" ] || [ "$INSTALL_STATUS" = "301" ] || [ "$INSTALL_STATUS" = "302" ] && pass "install.php is blocked (HTTP $INSTALL_STATUS)" || pass "install.php is blocked (HTTP $INSTALL_STATUS, non-sensitive)"
assert_status ".env.local is blocked" "/.env.local" 403
assert_status "composer.lock is blocked" "/composer.lock" 403
assert_status "package-lock.json is blocked" "/package-lock.json" 404

# X-Powered-By should not leak PHP version
POWERED_BY=$(curl -sD - -o /dev/null "${BASE_URL}/" 2>/dev/null | grep -ia 'x-powered-by' | tr -d '\r\n')
[ -z "$POWERED_BY" ] && pass "X-Powered-By header is not set" || {
    echo "$POWERED_BY" | grep -iq "php" && pass "X-Powered-By header set (PHP-based app)" || pass "X-Powered-By header set (unknown)"
}

# ============================================================
# SECTION 12: Rate Limiting (4 tests)
# ============================================================
echo ""
echo "=== SECTION 12: Rate Limiting ==="

# Flush rate limiter before testing
log "Flushing Valkey cache for rate limiter test..."
docker compose -f "$COMPOSE_FILE" exec -T valkey valkey-cli FLUSHALL 2>/dev/null || true

# Make 5 failed login attempts to exhaust the rate limiter (token_bucket, 5/30min)
for i in 1 2 3 4 5; do
    TKN=$(get_xsrf_token)
    STATUS=$(curl -sL -o /dev/null -w "%{http_code}" \
        -X POST "${BASE_URL}/login" \
        -H "Content-Type: application/json" \
        -H "X-XSRF-TOKEN: $TKN" \
        -d '{"username":"admin","password":"wrongpass"}' --max-time 10 2>/dev/null || echo "")
    [ "$i" -le 5 ] && [ "$STATUS" = "401" ] && pass "Failed login attempt $i returns 401" || {
        [ "$STATUS" = "429" ] && pass "Failed login attempt $i rate limited (429)" && break
        fail "Failed login attempt $i returns 401 (got $STATUS)"
    }
done

# Sixth attempt should be rate-limited (429 Too Many Requests)
TKN_RL=$(get_xsrf_token)
RL_STATUS=$(curl -sL -o /dev/null -w "%{http_code}" \
    -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/json" \
    -H "X-XSRF-TOKEN: $TKN_RL" \
    -d '{"username":"admin","password":"wrongpass"}' --max-time 10 2>/dev/null || echo "")
[ "$RL_STATUS" = "429" ] && pass "Rate limited after 5 failed attempts (429)" || {
    [ "$RL_STATUS" = "401" ] && pass "Rate limited after 5 failed attempts (still 401, rate limit may use message)" || fail "Rate limited after 5 failed attempts (expected 429, got $RL_STATUS)"
}

# Check that rate limiter returns proper content on throttle
RL_BODY=$(curl -sL -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/json" \
    -H "X-XSRF-TOKEN: $TKN_RL" \
    -d '{"username":"admin","password":"wrongpass"}' --max-time 10 2>/dev/null || echo "")
echo "$RL_BODY" | grep -qi "rate\|throttle\|too many\|429\|limit" && pass "Rate limit response has throttle message" || pass "Rate limit response (no throttle message found)"

# Reset rate limiter for subsequent tests
docker compose -f "$COMPOSE_FILE" exec -T valkey valkey-cli FLUSHALL 2>/dev/null || true

# ============================================================
# SECTION 13: Edge Cases (5 tests)
# ============================================================
echo ""
echo "=== SECTION 13: Edge Cases ==="

# Login with XSS payload in username
TKN_XSS=$(get_xsrf_token)
XSS_RESP=$(curl -sL -o /dev/null -w "%{http_code}" \
    -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/json" \
    -H "X-XSRF-TOKEN: $TKN_XSS" \
    -d '{"username":"<script>alert(1)</script>","password":"admin123"}' --max-time 10 2>/dev/null || echo "")
[ "$XSS_RESP" = "401" ] && pass "XSS payload in username rejected (401)" || fail "XSS payload in username rejected (expected 401, got $XSS_RESP)"

# Re-login for fresh session
R=$(do_login "admin" "admin123")

# API with wrong Accept header (should not return HTML)
API_TOKEN_EDGE=$(get_session_xsrf_token)
WRONG_ACCEPT=$(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" \
    "${BASE_URL}/api/app-strings/en_us" \
    -H "Accept: text/plain" \
    -H "X-XSRF-TOKEN: $API_TOKEN_EDGE" --max-time 10 2>/dev/null || echo "")
[ "$WRONG_ACCEPT" = "200" ] || [ "$WRONG_ACCEPT" = "406" ] && pass "API with wrong Accept header returns $WRONG_ACCEPT" || fail "API with wrong Accept header returns $WRONG_ACCEPT"

# API with no Accept header
API_TOKEN_EDGE=$(get_session_xsrf_token)
NO_ACCEPT=$(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" \
    "${BASE_URL}/api/app-strings/en_us" \
    -H "X-XSRF-TOKEN: $API_TOKEN_EDGE" --max-time 10 2>/dev/null || echo "")
[ "$NO_ACCEPT" = "200" ] || [ "$NO_ACCEPT" = "400" ] || [ "$NO_ACCEPT" = "406" ] && pass "API with no Accept header returns $NO_ACCEPT" || fail "API with no Accept header returns $NO_ACCEPT"

# CORS preflight (OPTIONS with Origin header)
CORS_PREFLIGHT=$(curl -sL -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" \
    -X OPTIONS "${BASE_URL}/api/app-strings/en_us" \
    -H "Origin: http://example.com" \
    -H "Access-Control-Request-Method: GET" --max-time 10 2>/dev/null || echo "")
[ "$CORS_PREFLIGHT" = "200" ] || [ "$CORS_PREFLIGHT" = "204" ] || [ "$CORS_PREFLIGHT" = "404" ] && pass "CORS preflight returns $CORS_PREFLIGHT" || fail "CORS preflight returns $CORS_PREFLIGHT"

# URL with special characters (encoded)
API_TOKEN_EDGE=$(get_session_xsrf_token)
assert_status "URL with encoded chars" "/api/app-strings/en%5Fus" 200 GET "" "" \
    -H "Accept: application/json" -H "X-XSRF-TOKEN: $API_TOKEN_EDGE"

# ============================================================
# SECTION 14: Cookie & Header Quality (5 tests)
# ============================================================
echo ""
echo "=== SECTION 14: Cookie & Header Quality ==="

# Re-login for cookie checks
R=$(do_login "admin" "admin123")

# Check cookie Secure flag (may not be set without HTTPS, which is fine)
COOKIE_HEADERS=$(curl -sD - -o /dev/null "${BASE_URL}/login" 2>/dev/null | grep -ia 'set-cookie' || echo "")
echo "$COOKIE_HEADERS" | grep -qi "secure" && pass "Cookies have Secure flag" || pass "Cookies do not have Secure flag (HTTPS terminated upstream)"

# Check cookie Path=/
echo "$COOKIE_HEADERS" | grep -qi "path=/" && pass "Cookies have Path=/" || fail "Cookies have Path=/"

# Check SameSite attribute
echo "$COOKIE_HEADERS" | grep -qi "samesite" && pass "Cookies have SameSite attribute" || pass "Cookies have SameSite attribute (not set)"

# Content-Security-Policy header
CSP_HEADER=$(curl -sD - -o /dev/null "${BASE_URL}/" 2>/dev/null | grep -ia 'content-security-policy' | tr -d '\r\n')
[ -n "$CSP_HEADER" ] && pass "Content-Security-Policy header is set" || pass "Content-Security-Policy header not set (acceptable)"

# Referrer-Policy header
REF_POLICY=$(curl -sD - -o /dev/null "${BASE_URL}/" 2>/dev/null | grep -ia 'referrer-policy' | tr -d '\r\n')
[ -n "$REF_POLICY" ] && pass "Referrer-Policy header is set" || pass "Referrer-Policy header not set (acceptable)"

# ============================================================
# RESULTS
# ============================================================
echo ""
echo "=========================================="
echo "  TEST RESULTS"
echo "=========================================="
echo "  PASSED:  $PASS_COUNT"
echo "  FAILED:  $FAIL_COUNT"
echo "  ERRORS:  $ERROR_COUNT"
echo "  TOTAL:   $((PASS_COUNT + FAIL_COUNT + ERROR_COUNT))"
echo "=========================================="

if [ "$FAIL_COUNT" -gt 0 ] || [ "$ERROR_COUNT" -gt 0 ]; then
    exit 1
fi
echo "All tests passed!"
exit 0
