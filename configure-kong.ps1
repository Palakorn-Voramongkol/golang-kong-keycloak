# configure-kong.ps1
# ──────────────────────────────────────────────────────────────────────────────
# Full setup so that *all* traffic—including login/token fetch and JWKS—
# passes through Kong at port 8081, then on to Keycloak (for /realms/...)
# and to your Go app (for /public, /profile, /user, /admin).
# ──────────────────────────────────────────────────────────────────────────────

param(
  [string]$KongAdminUrl     = "http://localhost:8001",  # Kong Admin API
  [string]$GatewayUrl       = "http://localhost:8081",  # Kong proxy for clients
  [string]$KeycloakIssuer   = "http://keycloak:8080/realms/demo-realm",
  [string]$AppName          = "go-app-service"
)

function Decode-Base64Url {
  param([string]$s)
  $s = $s.Replace('-', '+').Replace('_', '/')
  switch ($s.Length % 4) {
    2 { $s += '==' }
    3 { $s += '=' }
  }
  [Convert]::FromBase64String($s)
}

# 1) WAIT FOR KONG ADMIN
Write-Host "⏳ Waiting for Kong Admin API…" -NoNewline
while ($true) {
  try {
    Invoke-RestMethod -Uri "$KongAdminUrl/status" -ErrorAction Stop | Out-Null
    Write-Host " ✅" -ForegroundColor Green
    break
  } catch {
    Write-Host -NoNewline "."
    Start-Sleep 2
  }
}

# 2) CONFIGURE KEYCLOAK PROXY
Write-Host "`n🛠️  Setting up Keycloak service & route…" -ForegroundColor Cyan

# a) Service
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services" `
  -Body (@{ name = "keycloak-svc"; url = "http://keycloak:8080" } | ConvertTo-Json) `
  -ContentType "application/json"

# b) Single /auth prefix route (strip /auth → upstream /realms/...)
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services/keycloak-svc/routes" `
  -Body (@{
    name       = "keycloak-auth-route"
    paths      = @("/auth")
    strip_path = $true
    protocols  = @("http","https")
  } | ConvertTo-Json) `
  -ContentType "application/json"

# 3) FETCH THE RS256 JWK VIA KONG
Write-Host "`n🔑 Fetching RS256 JWK via Kong…" -ForegroundColor Cyan
try {
  $jwks = Invoke-RestMethod -Uri "$GatewayUrl/auth/realms/demo-realm/protocol/openid-connect/certs" -ErrorAction Stop
  $jwk  = $jwks.keys |
          Where-Object { $_.use -eq 'sig' -and $_.alg -eq 'RS256' } |
          Select-Object -First 1
  if (-not $jwk) { throw "No RS256 key found in JWKS." }
  Write-Host "✅ Got JWK (kid=$($jwk.kid))" -ForegroundColor Green
} catch {
  Write-Error "Failed to fetch JWKS: $_"
  exit 1
}

# 4) BUILD PEM PUBLIC KEY FROM n/e
Write-Host "`n🔨 Constructing PEM public key…" -ForegroundColor Cyan
try {
  $mod = Decode-Base64Url $jwk.n
  $exp = Decode-Base64Url $jwk.e
  $rsaParams = [System.Security.Cryptography.RSAParameters]@{
    Modulus  = $mod
    Exponent = $exp
  }
  $rsa = [System.Security.Cryptography.RSA]::Create()
  $rsa.ImportParameters($rsaParams)

  $spki = $rsa.ExportSubjectPublicKeyInfo()
  $b64  = [Convert]::ToBase64String($spki)
  $lines = ($b64 -split '(.{64})' | Where-Object { $_ -ne '' })
  $pemPublicKey = "-----BEGIN PUBLIC KEY-----`n" + ($lines -join "`n") + "`n-----END PUBLIC KEY-----"
  Write-Host "✅ PEM public key built." -ForegroundColor Green
} catch {
  Write-Error "Failed to build PEM: $_"
  exit 1
}

# 5) CLEAN UP PREVIOUS CONFIG
Write-Host "`n🧹 Cleaning up old Kong config…" -ForegroundColor Cyan
@(
  "/consumers/keycloak-users/jwt/$KeycloakIssuer",
  "/services/keycloak-svc",
  "/services/$AppName",
  "/consumers/keycloak-users"
) | ForEach-Object {
  try { Invoke-RestMethod -Method Delete -Uri "$KongAdminUrl$_" -ErrorAction SilentlyContinue } catch {}
}

# 6) CONFIGURE GO-APP SERVICE & ROUTES
Write-Host "`n🛠️  Setting up Go App service & routes…" -ForegroundColor Cyan

# a) Service
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services" `
  -Body (@{ name = $AppName; url = "http://app:3000" } | ConvertTo-Json) `
  -ContentType "application/json"

# b) Public endpoint (no JWT)
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services/$AppName/routes" `
  -Body (@{ name = "public-route"; paths = @("/public"); strip_path = $false } | ConvertTo-Json) `
  -ContentType "application/json"

# c) Protected endpoints
@("profile","user","admin") | ForEach-Object {
  Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services/$AppName/routes" `
    -Body (@{ name = "$($_)-route"; paths = @("/$_"); strip_path = $false } | ConvertTo-Json) `
    -ContentType "application/json"
}

# 7) CREATE CONSUMER & REGISTER PUBLIC KEY
Write-Host "`n👤 Creating consumer & registering JWT credential…" -ForegroundColor Cyan
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/consumers" `
  -Body (@{ username = "keycloak-users" } | ConvertTo-Json) `
  -ContentType "application/json"

$jwtCred = @{
  key            = $KeycloakIssuer
  algorithm      = "RS256"
  rsa_public_key = $pemPublicKey
}
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/consumers/keycloak-users/jwt" `
  -Body ($jwtCred | ConvertTo-Json -Depth 5) `
  -ContentType "application/json"

# 8) ATTACH JWT PLUGIN TO PROTECTED ROUTES
Write-Host "`n🔌 Securing protected routes with JWT…" -ForegroundColor Cyan
@("profile-route","user-route","admin-route") | ForEach-Object {
  Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/routes/$_/plugins" `
    -Body (@{ name = "jwt" } | ConvertTo-Json) `
    -ContentType "application/json"
}

Write-Host "`n🎉 All done! Kong gateway is live on $GatewayUrl" -ForegroundColor Green
Write-Host "  • Token & JWKS: $GatewayUrl/auth/realms/demo-realm/{protocol/openid-connect/token,protocol/openid-connect/certs}"
Write-Host "  • Public:       $GatewayUrl/public"
Write-Host "  • Profile:      $GatewayUrl/profile"
Write-Host "  • User:         $GatewayUrl/user"
Write-Host "  • Admin:        $GatewayUrl/admin"
