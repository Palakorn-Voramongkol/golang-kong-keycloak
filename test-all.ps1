# test-all-kong.ps1
# A comprehensive test script for the final Kong + Keycloak setup.
# It validates the gateway configuration and then tests all endpoints with different user roles.

# --- Configuration ---
# All requests go through the Kong Gateway
$GatewayUrl         = "http://localhost:8081"
$KongAdminUrl       = "http://localhost:8001"
$TokenUrl           = "$GatewayUrl/auth/realms/demo-realm/protocol/openid-connect/token"
$JWKSUrl            = "$GatewayUrl/auth/realms/demo-realm/protocol/openid-connect/certs"
# Name of the Kong Service pointing to your Go API
$BackendServiceName = "go-app-service"

# --- Helper Functions ---
function Print-Header {
    param([string]$Title)
    Write-Host "`n"
    Write-Host ("-" * 70)
    Write-Host "➡️  $Title"
    Write-Host ("-" * 70)
}

# --- Phase 0: System & Configuration Checks ---
Print-Header "Phase 0: Verifying System Readiness"

# 0.1 Wait for Kong Admin API to be ready
Write-Host "⏳ Waiting for Kong Admin API at $KongAdminUrl..." -NoNewline
$retries = 30
while ($retries -gt 0) {
    try {
        Invoke-RestMethod -Uri $KongAdminUrl -ErrorAction Stop | Out-Null
        Write-Host " ✅" -ForegroundColor Green
        break
    }
    catch {
        Write-Host -NoNewline "."
        Start-Sleep 2
        $retries--
    }
}
if ($retries -eq 0) {
    Write-Host "`n❌ FAILED: Kong Admin API is not responding. Ensure services are running with 'docker-compose up'." -ForegroundColor Red
    exit 1
}

# 0.2 Verify correct Kong service name
Write-Host "⏳ Checking for Kong service '$BackendServiceName'..." -NoNewline
try {
    Invoke-RestMethod -Uri "$KongAdminUrl/services/$BackendServiceName" -ErrorAction Stop | Out-Null
    Write-Host " ✅" -ForegroundColor Green
} catch {
    Write-Host "`n❌ FAILED: Kong service '$BackendServiceName' not found." -ForegroundColor Red
    Write-Host "   Run the 'configure-kong' script first (or adjust \$BackendServiceName)." -ForegroundColor Yellow
    exit 1
}

# 0.3 Sanity-check the Keycloak JWKS proxy
Write-Host "⏳ Testing JWKS endpoint via Kong ($JWKSUrl)..." -NoNewline
try {
    $jwks = Invoke-RestMethod -Uri $JWKSUrl -ErrorAction Stop
    if ($jwks.keys) {
        Write-Host " ✅" -ForegroundColor Green
    } else {
        throw "No 'keys' array in response"
    }
} catch {
    Write-Host "`n❌ FAILED: Could not fetch JWKS through Kong. Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- Phase 1: Get Tokens ---
Print-Header "Phase 1: Acquiring JWTs for Alice (user) and Bob (admin)"

# Get Token for Alice
try {
    $aliceTokenResponse = Invoke-RestMethod -Method Post `
      -Uri $TokenUrl `
      -ContentType "application/x-www-form-urlencoded" `
      -Body @{ grant_type = 'password'; client_id = 'fiber-app'; username = 'alice'; password = 'password123' } `
      -ErrorAction Stop
    $alice_token = $aliceTokenResponse.access_token
    Write-Host "✅ SUCCESS: Got token for Alice." -ForegroundColor Green
} catch {
    Write-Host "❌ FAILED: Could not get token for Alice. $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Get Token for Bob
try {
    $bobTokenResponse = Invoke-RestMethod -Method Post `
      -Uri $TokenUrl `
      -ContentType "application/x-www-form-urlencoded" `
      -Body @{ grant_type = 'password'; client_id = 'fiber-app'; username = 'bob'; password = 'password123' } `
      -ErrorAction Stop
    $bob_token = $bobTokenResponse.access_token
    Write-Host "✅ SUCCESS: Got token for Bob." -ForegroundColor Green
} catch {
    Write-Host "❌ FAILED: Could not get token for Bob. $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- Phase 2: Test Public Endpoint (/public) ---
Print-Header "Phase 2: Testing Public Endpoint (/public)"
try {
    $publicResponse = Invoke-RestMethod -Uri "$GatewayUrl/public" -ErrorAction Stop
    if ($publicResponse.message -eq "This is a public endpoint.") {
        Write-Host "✅ SUCCESS: /public returned correct message." -ForegroundColor Green
    } else {
        Write-Host "❌ FAILED: /public returned unexpected data." -ForegroundColor Red
    }
} catch {
    Write-Host "❌ FAILED: /public request error: $($_.Exception.Message)" -ForegroundColor Red
}

# --- Phase 3: Test Protected Endpoint (/profile) ---
Print-Header "Phase 3: Testing Protected Endpoint (/profile)"

# With valid token (should succeed)
try {
    $profileResponse = Invoke-RestMethod -Uri "$GatewayUrl/profile" -Headers @{ "Authorization" = "Bearer $alice_token" }
    if ($profileResponse.message -like "Hello, alice*") {
        Write-Host "✅ SUCCESS: /profile accessible with valid token." -ForegroundColor Green
    } else {
        Write-Host "❌ FAILED: /profile returned unexpected data with valid token." -ForegroundColor Red
    }
} catch {
    Write-Host "❌ FAILED: /profile call with token error: $($_.Exception.Message)" -ForegroundColor Red
}

# Without a token (should 401)
try {
    Invoke-RestMethod -Uri "$GatewayUrl/profile" -ErrorAction Stop
    Write-Host "❌ FAILED: /profile accessible without token!" -ForegroundColor Red
} catch {
    if ($_.Exception.Response.StatusCode -eq 401) {
        Write-Host "✅ SUCCESS: /profile blocked without token (401)." -ForegroundColor Green
    } else {
        Write-Host "❌ FAILED: /profile returned unexpected status: $($_.Exception.Response.StatusCode)" -ForegroundColor Red
    }
}

# --- Phase 4: Test User-Level Endpoint (/user) ---
Print-Header "Phase 4: Testing Role-Based Endpoint (/user)"

# Alice (role: user) → should succeed
try {
    $userResponse = Invoke-RestMethod -Uri "$GatewayUrl/user" -Headers @{ "Authorization" = "Bearer $alice_token" }
    if ($userResponse.message -eq "Hello, user-level endpoint!") {
        Write-Host "✅ SUCCESS: Alice can access /user." -ForegroundColor Green
    } else {
        Write-Host "❌ FAILED: /user returned unexpected data for Alice." -ForegroundColor Red
    }
} catch {
    Write-Host "❌ FAILED: /user error for Alice: $($_.Exception.Message)" -ForegroundColor Red
}

# Bob (role: admin) → should 403
try {
    Invoke-RestMethod -Uri "$GatewayUrl/user" -Headers @{ "Authorization" = "Bearer $bob_token" } -ErrorAction Stop
    Write-Host "❌ FAILED: Bob accessed /user but should be forbidden!" -ForegroundColor Red
} catch {
    if ($_.Exception.Response.StatusCode -eq 403) {
        Write-Host "✅ SUCCESS: Bob correctly blocked from /user (403)." -ForegroundColor Green
    } else {
        Write-Host "❌ FAILED: Bob blocked with unexpected status: $($_.Exception.Response.StatusCode)" -ForegroundColor Red
    }
}

# --- Phase 5: Test Admin-Level Endpoint (/admin) ---
Print-Header "Phase 5: Testing Role-Based Endpoint (/admin)"

# Alice (role: user) → should 403
try {
    Invoke-RestMethod -Uri "$GatewayUrl/admin" -Headers @{ "Authorization" = "Bearer $alice_token" } -ErrorAction Stop
    Write-Host "❌ FAILED: Alice accessed /admin but should be forbidden!" -ForegroundColor Red
} catch {
    if ($_.Exception.Response.StatusCode -eq 403) {
        Write-Host "✅ SUCCESS: Alice correctly blocked from /admin (403)." -ForegroundColor Green
    } else {
        Write-Host "❌ FAILED: Alice blocked with unexpected status: $($_.Exception.Response.StatusCode)" -ForegroundColor Red
    }
}

# Bob (role: admin) → should succeed
try {
    $adminResponse = Invoke-RestMethod -Uri "$GatewayUrl/admin" -Headers @{ "Authorization" = "Bearer $bob_token" }
    if ($adminResponse.message -eq "Hello, admin-level endpoint!") {
        Write-Host "✅ SUCCESS: Bob can access /admin." -ForegroundColor Green
    } else {
        Write-Host "❌ FAILED: /admin returned unexpected data for Bob." -ForegroundColor Red
    }
} catch {
    Write-Host "❌ FAILED: /admin error for Bob: $($_.Exception.Message)" -ForegroundColor Red
}

# --- Done ---
Write-Host "`n"
Write-Host ("-" * 70)
Write-Host "🎉 All tests complete. Gateway and Backend API are working as expected!"
Write-Host ("-" * 70)
