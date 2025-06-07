#!/bin/sh
# This script configures a running Kong instance for Linux/macOS users.
# It requires curl, jq, and openssl to be installed on the host machine.
set -e

# --- Configuration ---
KONG_ADMIN_URL="http://localhost:8001"
KEYCLOAK_CERTS_URL="http://localhost:8080/realms/demo-realm/protocol/openid-connect/certs"
APP_NAME="go-app-service"
KEYCLOAK_ISSUER="http://localhost:8080/realms/demo-realm"

# --- Script Body ---

# 1) Wait for Kong Admin API
echo "⏳ Waiting for Kong Admin API at $KONG_ADMIN_URL…"
until curl -s -f -o /dev/null "$KONG_ADMIN_URL/status"; do
  printf '.'
  sleep 5
done
echo "\n✅ Kong Admin is up!"

# 2) Fetch the RS256 JWK from Keycloak
echo "\n🔑 Fetching RS256 JWK from Keycloak…"
JWKS=$(curl -s "$KEYCLOAK_CERTS_URL")
if [ -z "$JWKS" ]; then
  echo "❌ Failed to fetch JWKS from Keycloak. Is it running?"
  exit 1
fi

# Use jq to parse the JSON and find the signing key
KID=$(echo "$JWKS" | jq -r '.keys[] | select(.use=="sig" and .alg=="RS256") | .kid')
MODULUS_B64_URL=$(echo "$JWKS" | jq -r '.keys[] | select(.use=="sig" and .alg=="RS256") | .n')
EXPONENT_B64_URL=$(echo "$JWKS" | jq -r '.keys[] | select(.use=="sig" and .alg=="RS256") | .e')

if [ -z "$KID" ]; then
  echo "❌ No RS256 signing key found in JWKS."
  exit 1
fi
echo "✅ Got JWK (kid = $KID)"

# 3) Build the PEM public key using openssl
echo "\n🔨 Building RSA public key from n/e components…"
# openssl requires a specific JSON format to convert from JWK to PEM
PEM_PUBLIC_KEY=$(printf '{"keys":[{"kty":"RSA","e":"%s","n":"%s"}]}' "$EXPONENT_B64_URL" "$MODULUS_B64_URL" | openssl pkey -pubin -inform JWK -outform PEM)
if [ -z "$PEM_PUBLIC_KEY" ]; then
  echo "❌ Failed to build PEM key with openssl."
  exit 1
fi
echo "✅ PEM public key built."

# 4) Clean up old Kong config
echo "\n🧹 Cleaning up old Kong config…"
curl -s -X DELETE "$KONG_ADMIN_URL/consumers/keycloak-users/jwt/$KEYCLOAK_ISSUER" > /dev/null || true
curl -s -X DELETE "$KONG_ADMIN_URL/services/$APP_NAME" > /dev/null || true
curl -s -X DELETE "$KONG_ADMIN_URL/consumers/keycloak-users" > /dev/null || true

# 5) Create Service & ALL Routes
echo "\n🛠️  Creating Service & All Routes…"
curl -s -X POST "$KONG_ADMIN_URL/services" \
  --header 'Content-Type: application/json' \
  --data '{"name":"'"$APP_NAME"'","url":"http://app:3000"}'

curl -s -X POST "$KONG_ADMIN_URL/services/$APP_NAME/routes" \
  --header 'Content-Type: application/json' \
  --data '{"name":"public-route","paths":["/public"],"strip_path":false}'

curl -s -X POST "$KONG_ADMIN_URL/services/$APP_NAME/routes" \
  --header 'Content-Type: application/json' \
  --data '{"name":"profile-route","paths":["/profile"],"strip_path":false}'

curl -s -X POST "$KONG_ADMIN_URL/services/$APP_NAME/routes" \
  --header 'Content-Type: application/json' \
  --data '{"name":"user-route","paths":["/user"],"strip_path":false}'

curl -s -X POST "$KONG_ADMIN_URL/services/$APP_NAME/routes" \
  --header 'Content-Type: application/json' \
  --data '{"name":"admin-route","paths":["/admin"],"strip_path":false}'

# 6) Create Consumer
echo "\n👤 Creating Consumer 'keycloak-users'…"
curl -s -X POST "$KONG_ADMIN_URL/consumers" \
  --header 'Content-Type: application/json' \
  --data '{"username":"keycloak-users"}'

# 7) Register rsa_public_key with the consumer
echo "🔐 Registering RSA public key for consumer…"
# Use jq to build the JSON payload to handle the multi-line PEM key correctly
JSON_PAYLOAD=$(jq -n \
  --arg key "$KEYCLOAK_ISSUER" \
  --arg alg "RS256" \
  --arg pem "$PEM_PUBLIC_KEY" \
  '{"key": $key, "algorithm": $alg, "rsa_public_key": $pem}')

curl -s -X POST "$KONG_ADMIN_URL/consumers/keycloak-users/jwt" \
  --header 'Content-Type: application/json' \
  --data "$JSON_PAYLOAD"

# 8) Attach JWT plugin to EACH protected route
echo "\n🔌 Attaching JWT plugin to protected routes…"
curl -s -X POST "$KONG_ADMIN_URL/routes/profile-route/plugins" --header 'Content-Type: application/json' --data '{"name":"jwt"}'
curl -s -X POST "$KONG_ADMIN_URL/routes/user-route/plugins" --header 'Content-Type: application/json' --data '{"name":"jwt"}'
curl -s -X POST "$KONG_ADMIN_URL/routes/admin-route/plugins" --header 'Content-Type: application/json' --data '{"name":"jwt"}'

echo "\n🎉 Done! Kong is configured:"
echo "   • http://localhost:8081/public  → no auth"
echo "   • http://localhost:8081/profile → JWT required"
echo "   • http://localhost:8081/user    → JWT required"
echo "   • http://localhost:8081/admin   → JWT required"