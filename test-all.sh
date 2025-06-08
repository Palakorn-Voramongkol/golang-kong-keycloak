#!/usr/bin/env bash
# test-all-kong.sh
# A comprehensive test script for the final Kong + Keycloak setup.
# It validates the gateway configuration and then tests all endpoints with different user roles.

set -euo pipefail
IFS=$'\n\t'

# --- Configuration ---
GatewayUrl="http://localhost:8081"
KongAdminUrl="http://localhost:8001"
TokenUrl="$GatewayUrl/auth/realms/demo-realm/protocol/openid-connect/token"
JWKSUrl="$GatewayUrl/auth/realms/demo-realm/protocol/openid-connect/certs"
BackendServiceName="go-app-service"

# ANSI colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # no color

# --- Helper Function to Print Headers ---
print_header() {
  title="$1"
  printf "\n%.0s-" {1..70}
  printf "\n➡️  %s\n" "$title"
  printf "%.0s-" {1..70}
  echo
}

failures=0

# --- Phase 0: System & Configuration Checks ---
print_header "Phase 0: Verifying System Readiness"

# 0.1 Wait for Kong Admin API
printf "⏳ Waiting for Kong Admin API at %s" "$KongAdminUrl"
until curl -s "$KongAdminUrl" > /dev/null; do
  printf "."
  sleep 2
done
printf " ${GREEN}✅${NC}\n"

# 0.2 Verify correct Kong service name
printf "⏳ Checking for Kong service '%s'..." "$BackendServiceName"
status=$(curl -s -o /dev/null -w "%{http_code}" "${KongAdminUrl}/services/${BackendServiceName}")
if [[ "$status" -eq 200 ]]; then
  printf " ${GREEN}✅${NC}\n"
else
  printf " ${RED}❌${NC}\n"
  echo -e "${YELLOW}Run the 'configure-kong' script first or adjust BackendServiceName.${NC}"
  exit 1
fi

# 0.3 Sanity-check the Keycloak JWKS proxy
printf "⏳ Testing JWKS endpoint via Kong (%s)..." "$JWKSUrl"
jwks=$(curl -s "$JWKSUrl")
if jq -e '.keys | length > 0' <<<"$jwks" > /dev/null; then
  printf " ${GREEN}✅${NC}\n"
else
  printf " ${RED}❌${NC}\n"
  echo -e "${RED}Could not fetch JWKS or no keys found.${NC}"
  exit 1
fi

# --- Phase 1: Get Tokens ---
print_header "Phase 1: Acquiring JWTs for Alice (user) and Bob (admin)"

# Alice
if alice_token=$(curl -s -X POST "$TokenUrl" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "grant_type=password&client_id=fiber-app&username=alice&password=password123" \
    | jq -r '.access_token'); then
  if [[ -n "$alice_token" && "$alice_token" != "null" ]]; then
    echo -e "${GREEN}✅ SUCCESS${NC}: Got token for Alice."
  else
    echo -e "${RED}❌ FAILED${NC}: No token for Alice."
    failures=$((failures+1))
  fi
else
  echo -e "${RED}❌ FAILED${NC}: Could not get token for Alice."
  failures=$((failures+1))
fi

# Bob
if bob_token=$(curl -s -X POST "$TokenUrl" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "grant_type=password&client_id=fiber-app&username=bob&password=password123" \
    | jq -r '.access_token'); then
  if [[ -n "$bob_token" && "$bob_token" != "null" ]]; then
    echo -e "${GREEN}✅ SUCCESS${NC}: Got token for Bob."
  else
    echo -e "${RED}❌ FAILED${NC}: No token for Bob."
    failures=$((failures+1))
  fi
else
  echo -e "${RED}❌ FAILED${NC}: Could not get token for Bob."
  failures=$((failures+1))
fi

# --- Phase 2: Test Public Endpoint (/public) ---
print_header "Phase 2: Testing Public Endpoint (/public)"
public_msg=$(curl -s "$GatewayUrl/public" | jq -r '.message // empty')
if [[ "$public_msg" == "This is a public endpoint." ]]; then
  echo -e "${GREEN}✅ SUCCESS${NC}: /public returned correct message."
else
  echo -e "${RED}❌ FAILED${NC}: /public returned: $public_msg"
  failures=$((failures+1))
fi

# --- Phase 3: Test Protected Endpoint (/profile) ---
print_header "Phase 3: Testing Protected Endpoint (/profile)"

# With valid token
profile_msg=$(curl -s -H "Authorization: Bearer $alice_token" "$GatewayUrl/profile" | jq -r '.message // empty')
if [[ "$profile_msg" == Hello,\ alice* ]]; then
  echo -e "${GREEN}✅ SUCCESS${NC}: /profile accessible with valid token."
else
  echo -e "${RED}❌ FAILED${NC}: /profile (valid token) returned: $profile_msg"
  failures=$((failures+1))
fi

# Without token
status=$(curl -s -o /dev/null -w "%{http_code}" "$GatewayUrl/profile")
if [[ "$status" -eq 401 ]]; then
  echo -e "${GREEN}✅ SUCCESS${NC}: /profile blocked without token (401)."
else
  echo -e "${RED}❌ FAILED${NC}: /profile without token returned $status"
  failures=$((failures+1))
fi

# --- Phase 4: Test Role-Based Endpoint (/user) ---
print_header "Phase 4: Testing Role-Based Endpoint (/user)"

# Alice (should succeed)
user_msg=$(curl -s -H "Authorization: Bearer $alice_token" "$GatewayUrl/user" | jq -r '.message // empty')
if [[ "$user_msg" == "Hello, user-level endpoint!" ]]; then
  echo -e "${GREEN}✅ SUCCESS${NC}: Alice can access /user."
else
  echo -e "${RED}❌ FAILED${NC}: /user (Alice) returned: $user_msg"
  failures=$((failures+1))
fi

# Bob (should 403)
status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $bob_token" "$GatewayUrl/user")
if [[ "$status" -eq 403 ]]; then
  echo -e "${GREEN}✅ SUCCESS${NC}: Bob correctly blocked from /user (403)."
else
  echo -e "${RED}❌ FAILED${NC}: /user (Bob) returned $status"
  failures=$((failures+1))
fi

# --- Phase 5: Test Role-Based Endpoint (/admin) ---
print_header "Phase 5: Testing Role-Based Endpoint (/admin)"

# Alice (should 403)
status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $alice_token" "$GatewayUrl/admin")
if [[ "$status" -eq 403 ]]; then
  echo -e "${GREEN}✅ SUCCESS${NC}: Alice correctly blocked from /admin (403)."
else
  echo -e "${RED}❌ FAILED${NC}: /admin (Alice) returned $status"
  failures=$((failures+1))
fi

# Bob (should succeed)
admin_msg=$(curl -s -H "Authorization: Bearer $bob_token" "$GatewayUrl/admin" | jq -r '.message // empty')
if [[ "$admin_msg" == "Hello, admin-level endpoint!" ]]; then
  echo -e "${GREEN}✅ SUCCESS${NC}: Bob can access /admin."
else
  echo -e "${RED}❌ FAILED${NC}: /admin (Bob) returned: $admin_msg"
  failures=$((failures+1))
fi

# --- Summary ---
printf "\n%.0s-" {1..70}
echo
if [[ "$failures" -eq 0 ]]; then
  echo -e "${GREEN}🎉 All tests complete. Gateway and Backend API are working as expected! 🎉${NC}"
  exit 0
else
  echo -e "${RED}⚠️  Some tests failed (${failures} failures).${NC}"
  exit 1
fi
