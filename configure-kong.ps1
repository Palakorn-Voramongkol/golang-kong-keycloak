# configure-kong.ps1

# This script configures a running Kong instance.
# Run it from your PowerShell terminal after 'docker-compose up' has finished
# and all services are healthy.

# --- Configuration ---
$KongAdminUrl = "http://localhost:8001"
$KeycloakCertsUrl = "http://localhost:8080/realms/demo-realm/protocol/openid-connect/certs"
$AppName = "go-app-service"

# --- Script Body ---
Write-Host "Waiting for Kong Admin API to be ready at $KongAdminUrl..." -ForegroundColor Yellow

# Loop until Kong is ready
while ($true) {
    try {
        $status = Invoke-RestMethod -Uri "$KongAdminUrl/status" -ErrorAction Stop
        if ($status) {
            Write-Host "Kong is ready!" -ForegroundColor Green
            break
        }
    }
    catch {
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 5
    }
}

Write-Host "Fetching public key from Keycloak..."
try {
    $jwks = Invoke-RestMethod -Uri $KeycloakCertsUrl
    $signingKey = $jwks.keys | Where-Object { $_.use -eq 'sig' }
    if (-not $signingKey) {
        Write-Host "Could not find signing key in JWKS from Keycloak. Aborting." -ForegroundColor Red
        exit 1
    }
    $kid = $signingKey.kid
    $alg = $signingKey.alg
    $x5c = $signingKey.x5c[0]
    $publicKey = "-----BEGIN PUBLIC KEY-----`n$x5c`n-----END PUBLIC KEY-----"

    Write-Host "Successfully fetched key with kid: $kid" -ForegroundColor Green
}
catch {
    Write-Host "Failed to fetch keys from Keycloak at $KeycloakCertsUrl. Is Keycloak running?" -ForegroundColor Red
    exit 1
}

Write-Host "Applying configuration to Kong..."

# 1. Create Service
Write-Host "  - Creating Service: $AppName"
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services" -ContentType "application/json" -Body "{`"name`":`"$AppName`", `"url`":`"http://app:3000`"}"

# 2. Create Routes
Write-Host "  - Creating Route: /public"
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services/$AppName/routes" -ContentType "application/json" -Body "{`"name`":`"public-route`", `"paths`":[`"/public`"]}"
Write-Host "  - Creating Route: /profile"
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services/$AppName/routes" -ContentType "application/json" -Body "{`"name`":`"profile-route`", `"paths`":[`"/profile`"]}"

# 3. Enable JWT Plugin on the Service
Write-Host "  - Enabling JWT plugin"
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services/$AppName/plugins" -ContentType "application/json" -Body "{`"name`":`"jwt`"}"

# 4. Create Consumer
Write-Host "  - Creating Consumer: keycloak-users"
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/consumers" -ContentType "application/json" -Body "{`"username`":`"keycloak-users`"}"

# 5. Add Keycloak's Public Key to the Consumer
Write-Host "  - Registering Keycloak public key with consumer"
$jwtBody = @{
    key    = $kid
    algorithm = $alg
    rsa_public_key = $publicKey
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/consumers/keycloak-users/jwt" -Body $jwtBody -ContentType "application/json"

Write-Host "`nConfiguration complete! Your gateway is ready." -ForegroundColor Green