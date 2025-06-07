# configure-kong.ps1
# ──────────────────────────────────────────────────────────────────────────────
# Configures Kong CE to protect /profile with Keycloak JWT, leaving /public open.
# Builds a true PEM public key from the JWK's n/e parameters.
# ──────────────────────────────────────────────────────────────────────────────

param(
  [string]$KongAdminUrl     = "http://localhost:8001",
  [string]$KeycloakCertsUrl = "http://localhost:8080/realms/demo-realm/protocol/openid-connect/certs",
  [string]$AppName          = "go-app-service",
  [string]$KeycloakIssuer   = "http://localhost:8080/realms/demo-realm"
)

function Decode-Base64Url {
  param([string]$s)
  $s = $s.Replace('-','+').Replace('_','/')
  switch ($s.Length % 4) {
    2 { $s += '==' }
    3 { $s += '=' }
  }
  return [Convert]::FromBase64String($s)
}

# 1) Wait for Kong Admin
Write-Host "⏳ Waiting for Kong Admin API at $KongAdminUrl…" -ForegroundColor Yellow
while ($true) {
  try {
    Invoke-RestMethod -Uri "$KongAdminUrl/status" -ErrorAction Stop | Out-Null
    Write-Host "✅ Kong Admin is up!" -ForegroundColor Green; break
  } catch {
    Write-Host -NoNewline "."; Start-Sleep 5
  }
}

# 2) Fetch the RS256 JWK
Write-Host "`n🔑 Fetching RS256 JWK from Keycloak…" -ForegroundColor Cyan
try {
  $jwks = Invoke-RestMethod -Uri $KeycloakCertsUrl -ErrorAction Stop
  $jwk  = $jwks.keys | Where-Object { $_.use -eq 'sig' -and $_.alg -eq 'RS256' } | Select-Object -First 1
  if (-not $jwk) { throw "No RS256 key found." }
  Write-Host "✅ Got JWK (kid = $($jwk.kid))" -ForegroundColor Green
} catch {
  Write-Error "Failed to fetch or parse JWKS: $_"; exit 1
}

# 3) Build the RSAParameters from n & e
Write-Host "`n🔨 Building RSA public key from n/e…" -ForegroundColor Cyan
try {
  $modulus  = Decode-Base64Url $jwk.n
  $exponent = Decode-Base64Url $jwk.e

  $rsaParams = New-Object System.Security.Cryptography.RSAParameters
  $rsaParams.Modulus  = $modulus
  $rsaParams.Exponent = $exponent

  $rsa = [System.Security.Cryptography.RSA]::Create()
  $rsa.ImportParameters($rsaParams)

  # Export to DER (SubjectPublicKeyInfo)
  $spki = $rsa.ExportSubjectPublicKeyInfo()
  $b64  = [Convert]::ToBase64String($spki)
  $lines = ($b64 -split '(.{64})' | Where-Object { $_ -ne '' })
  $pemPublicKey = "-----BEGIN PUBLIC KEY-----`n" + ($lines -join "`n") + "`n-----END PUBLIC KEY-----"
  Write-Host "✅ PEM public key built." -ForegroundColor Green
} catch {
  Write-Error "Failed to build RSA public key: $_"; exit 1
}

# 4) Clean up old config
Write-Host "`n🧹 Cleaning up old Kong config…" -ForegroundColor Cyan
@(
  "/consumers/keycloak-users/jwt/$KeycloakIssuer",
  "/services/$AppName",
  "/consumers/keycloak-users"
) | ForEach-Object {
  try { Invoke-RestMethod -Method Delete -Uri "$KongAdminUrl$_" -ErrorAction SilentlyContinue } catch {}
}

# 5) Create Service & Routes
Write-Host "`n🛠️  Creating Service & Routes…" -ForegroundColor Cyan
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services" `
    -Body (@{ name = $AppName; url = "http://app:3000" } | ConvertTo-Json) `
    -ContentType "application/json"

Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services/$AppName/routes" `
    -Body (@{ name = "public-route";  paths = @("/public")  } | ConvertTo-Json) `
    -ContentType "application/json"

Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services/$AppName/routes" `
    -Body (@{ name = "profile-route"; paths = @("/profile") } | ConvertTo-Json) `
    -ContentType "application/json"

# 6) Create Consumer
Write-Host "`n👤 Creating Consumer 'keycloak-users'…" -ForegroundColor Cyan
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/consumers" `
    -Body (@{ username = "keycloak-users" } | ConvertTo-Json) `
    -ContentType "application/json"

# 7) Register rsa_public_key under RS256
Write-Host "🔐 Registering rsa_public_key for consumer…" -ForegroundColor Cyan
$jwtCred = @{
  key            = $KeycloakIssuer
  algorithm      = "RS256"
  rsa_public_key = $pemPublicKey
}
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/consumers/keycloak-users/jwt" `
    -Body ($jwtCred | ConvertTo-Json -Depth 5) `
    -ContentType "application/json"

# 8) Attach JWT plugin only to /profile
Write-Host "`n🔌 Attaching JWT plugin to /profile route…" -ForegroundColor Cyan
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/routes/profile-route/plugins" `
    -Body (@{ name = "jwt" } | ConvertTo-Json) `
    -ContentType "application/json"

Write-Host "`n🎉 Done! Kong is configured:" -ForegroundColor Green
Write-Host "   • http://localhost:8081/public  → no auth"
Write-Host "   • http://localhost:8081/profile → JWT required" -ForegroundColor Green
