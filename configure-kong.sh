#!/bin/sh
# This script will run after the 'kong' service is healthy.
set -e

echo "Waiting for Keycloak to be ready..."
# Keycloak can be slow, so we poll its health endpoint
# Note: We are using the internal Docker network hostname 'keycloak'
until curl -s -f -o /dev/null http://keycloak:8080/health/ready; do
  printf '.'
  sleep 5
done

echo "Keycloak is ready. Fetching JWKS..."

# Fetch the JWKS data from Keycloak
# We need to extract the kid, alg, and x5c values
JWKS=$(curl -s http://keycloak:8080/realms/demo-realm/protocol/openid-connect/certs)
KID=$(echo "$JWKS" | jq -r '.keys[] | select(.use=="sig") | .kid')
ALG=$(echo "$JWKS" | jq -r '.keys[] | select(.use=="sig") | .alg')
X5C=$(echo "$JWKS" | jq -r '.keys[] | select(.use=="sig") | .x5c[0]')

# Create the full PEM format for the public key
PUBLIC_KEY="-----BEGIN PUBLIC KEY-----\n$X5C\n-----END PUBLIC KEY-----"

echo "--------------------------------"
echo "Kong is ready. Applying configuration..."
echo "Using Key ID (kid): $KID"
echo "--------------------------------"

# 1. Create the Service
curl -s -X POST http://kong:8001/services \
  --data name=go-app-service \
  --data url=http://app:3000

# 2. Create Routes
curl -s -X POST http://kong:8001/services/go-app-service/routes \
  --data name=public-route \
  --data paths[]=/public

curl -s -X POST http://kong:8001/services/go-app-service/routes \
  --data name=profile-route \
  --data paths[]=/profile

# 3. Enable the JWT Plugin on the Service
curl -s -X POST http://kong:8001/services/go-app-service/plugins \
  --data name=jwt

# 4. Create a Consumer
curl -s -X POST http://kong:8001/consumers \
  --data username=keycloak-users

# 5. Add Keycloak's Public Key to the Consumer
curl -s -X POST http://kong:8001/consumers/keycloak-users/jwt \
  -H "Content-Type: application/json" \
  -d '{
    "key": "'"$KID"'",
    "algorithm": "'"$ALG"'",
    "rsa_public_key": "'"$PUBLIC_KEY"'"
  }'

echo "\nKong configuration complete."