# configure-kong.ps1

$KongAdminUrl = "http://localhost:8001"
$KeycloakCertsUrl = "http://localhost:8080/realms/demo-realm/protocol/openid-connect/certs"
$AppName = "go-app-service"

# --- Script Body ---
Write-Host "Waiting for Kong Admin API to be ready..."
while ($true) { try { Invoke-RestMethod -Uri "$KongAdminUrl/status" -ErrorAction Stop; Write-Host "Kong is ready!"; break } catch { Write-Host -NoNewline "."; Start-Sleep 5 } }

Write-Host "Fetching public key from Keycloak..."
try {
    $jwks = Invoke-RestMethod -Uri $KeycloakCertsUrl
    $signingKey = $jwks.keys | Where-Object { $_.use -eq 'sig' -and $_.alg -eq 'RS256' } | Select-Object -First 1
    if (-not $signingKey) {
        Write-Host "Could not find RS256 signing key in JWKS from Keycloak. Aborting." -ForegroundColor Red
        exit 1
    }
    $kid = $signingKey.kid
    $alg = $signingKey.alg
    $x5c = $signingKey.x5c[0]

    # Manually build the PEM string line-by-line to ensure correct formatting
    $pemBody = ""
    for ($i = 0; $i -lt $x5c.Length; $i += 64) {
        $end = [System.Math]::Min($i + 64, $x5c.Length)
        $pemBody += $x5c.Substring($i, $end - $i) + "\n" # Use literal \n
    }
    # Trim the final newline character
    $pemBody = $pemBody.TrimEnd()
    $publicKeyForJson = "-----BEGIN PUBLIC KEY-----\n$pemBody\n-----END PUBLIC KEY-----"

    Write-Host "Successfully fetched key with kid: $kid" -ForegroundColor Green
}
catch {
    Write-Host "Failed to fetch keys from Keycloak. Is Keycloak running?" -ForegroundColor Red
    exit 1
}

Write-Host "Applying configuration to Kong..."

# Clean up previous attempts
try {
    Invoke-RestMethod -Method Delete -Uri "$KongAdminUrl/consumers/keycloak-users/jwt/$kid" -ErrorAction SilentlyContinue
    Invoke-RestMethod -Method Delete -Uri "$KongAdminUrl/consumers/keycloak-users" -ErrorAction SilentlyContinue
    Invoke-RestMethod -Method Delete -Uri "$KongAdminUrl/services/$AppName" -ErrorAction SilentlyContinue
} catch {}

# Create Service, Routes, and base JWT Plugin
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services" -Body "{`"name`":`"$AppName`", `"url`":`"http://app:3000`"}" -ContentType "application/json"
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services/$AppName/routes" -Body "{`"name`":`"public-route`", `"paths`":[`"/public`"]}" -ContentType "application/json"
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services/$AppName/routes" -Body "{`"name`":`"profile-route`", `"paths`":[`"/profile`"]}" -ContentType "application/json"
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/services/$AppName/plugins" -Body "{`"name`":`"jwt`"}" -ContentType "application/json"

# Disable JWT on public route
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/routes/public-route/plugins" -Body "{`"name`":`"jwt`", `"enabled`":false}" -ContentType "application/json"

# Create Consumer
Invoke-RestMethod -Method Post -Uri "$KongAdminUrl/consumers" -Body "{`"username`":`"keycloak-users`"}" -ContentType "application/json"

# --- THIS IS THE FINAL FIX ---
# Create the JSON payload as a here-string and then replace the newline
# characters with the literal `\n` that the JSON parser expects.
Write-Host "  - Registering Keycloak public key with consumer"
$jsonPayload = @"
{
    "key": "$kid",
    "algorithm": "$alg",
    "rsa_public_key": "$publicKeyForJson"
}
"@

# Replace the PowerShell newline `r`n with a literal \n for the JSON body
$cleanJsonBody = $jsonPayload.Replace("`r`n", "`n").Replace("`n", "\n")

# Use curl.exe directly, as it handles raw string bodies more reliably than Invoke-RestMethod
curl.exe -X POST `
  -H "Content-Type: application/json" `
  -d $cleanJsonBody `
  http://localhost:8001/consumers/keycloak-users/jwt

Write-Host "`nConfiguration complete! Your gateway is ready." -ForegroundColor Green