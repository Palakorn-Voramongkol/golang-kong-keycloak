# Secure Go API with Kong (DB-Backed) and Keycloak

This project demonstrates a complete, production-ready setup for securing a Go backend API using **Kong** as an API Gateway in **DB-Backed Mode** and Keycloak for identity and access management.

Running Kong with a database is the standard approach for production environments that require dynamic configuration, high availability, and the ability to manage the gateway via its Admin API. This setup uses Kong's built-in `jwt` plugin for maximum stability and performance.

## Architecture & Flow

The runtime architecture uses Kong to protect the backend service. All configuration is applied dynamically to Kong's database via its Admin API after startup.

```mermaid
sequenceDiagram
    participant Client
    participant Kong Gateway as GW (:8081)
    participant Keycloak as KC (:8080)
    participant Go App as App (:3000)
    participant Admin Script
    participant Kong Admin API as Admin (:8001)
    participant Kong DB

    Note over Admin Script, Kong DB: Initial Setup
    activate Admin
    Admin Script->>Admin: POST /services (Create go-app-service)
    Admin->>Kong DB: Store service
    Admin Script->>Admin: POST /routes (Create /profile)
    Admin->>Kong DB: Store route
    Admin Script->>Admin: POST /plugins (Attach JWT)
    Admin->>Kong DB: Store plugin config
    Admin Script->>Admin: POST /consumers (Create keycloak-users)
    Admin->>Kong DB: Store consumer
    Admin Script->>KC: GET /certs (Fetch public key)
    KC-->>Admin Script: JWKS Data
    Admin Script->>Admin: POST /consumers/keycloak-users/jwt (Add public key)
    Admin->>Kong DB: Store JWT secret
    deactivate Admin
    
    Note over Client, Go App: Runtime Request
    Client->>+KC: Request token (user: alice, pass: ...)
    KC-->>-Client: JWT

    Client->>+GW: GET /profile (Authorization: Bearer JWT)
    
    Note over GW: Validate JWT using stored public key
    Note over GW: JWT is valid!

    GW->>+App: GET /profile (Forward request)
    App-->>-GW: 200 OK ({"message":"Hello, alice", ...})
    GW-->>-Client: 200 OK ({"message":"Hello, alice", ...})
```

## How to Run

1.  **Prerequisites:**
    *   **For Windows:** No extra tools are needed.
    *   **For Linux/macOS:** You must have `curl`, `jq`, and `openssl` installed.
        *   *Ubuntu/Debian:* `sudo apt-get install -y curl jq openssl`
        *   *macOS (Homebrew):* `brew install curl jq openssl`

2.  **Clean up previous volumes (Important for a fresh start):**
    ```bash
    docker-compose down -v
    ```

3.  **Build and start all services:**
    The `--build` flag is only needed if you change the Go application's `Dockerfile`.
    ```bash
    docker-compose up --build -d
    ```

4.  **Wait for all services to initialize.**
    This is a critical step. Wait about **60-90 seconds** after the command finishes to ensure Keycloak and Kong are fully ready. You can monitor the status with `docker-compose ps`.

5.  **Configure Kong automatically using the correct script for your OS:**

    *   **On Windows (PowerShell):**
        ```powershell
        .\configure-kong.ps1
        ```

    *   **On Linux or macOS (Bash/Shell):**
        First, make the script executable:
        ```bash
        chmod +x configure-kong.sh
        ```
        Then, run it:
        ```bash
        ./configure-kong.sh
        ```
    You should see output confirming that the service, routes, and credentials were created successfully.

## Testing the Endpoints

After the configuration script has run, your gateway is ready to test.

**1. Get a Token for `alice` (user):**
*This example uses PowerShell, but you can use any HTTP client.*
```powershell
$resp = Invoke-RestMethod -Method Post `
  -Uri http://localhost:8080/realms/demo-realm/protocol/openid-connect/token `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{
    grant_type = 'password'
    client_id  = 'fiber-app'
    username   = 'alice'
    password   = 'password123'
  }
$token = $resp.access_token
```

**2. Test the Public Endpoint (succeeds):**
```bash
curl http://localhost:8081/public
```

**3. Test the Profile Endpoint (succeeds):**
```bash
# In PowerShell:
curl -H "Authorization: Bearer $token" http://localhost:8081/profile

# In Bash/Shell (after getting a token):
# curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/profile
```

**4. Test without a Token (fails with 401):**
```bash
curl -v http://localhost:8081/profile
```

**5. Test Admin Route:**
Get a token for `bob` (admin) and try accessing `http://localhost:8081/admin`. It will succeed.

## Deep Dive: Kong Configuration

This project uses Kong's stable, **built-in `jwt` plugin** and a **route-based security** approach.

1.  **Service:** We define a single `go-app-service` pointing to our backend.
2.  **Routes:** We create a separate route for each endpoint (`/public`, `/profile`, etc.). This gives us granular control.
3.  **Plugin Attachment:** The `jwt` plugin is **only** attached to the protected routes (`/profile`, `/user`, `/admin`). The `/public` route has no plugins and is therefore open.
4.  **Consumer and JWT Credential:**
    *   We create a generic `keycloak-users` consumer to represent clients authenticated by Keycloak.
    *   We then register a JWT Credential against this consumer. The most important part of this credential is the **RSA Public Key**, which is built from the `n` and `e` values of Keycloak's JWK.
    *   The `key` of the credential is set to the **issuer URL** from the JWT. When Kong receives a token, it looks at the `iss` claim and uses it to find the correct public key to verify the signature.