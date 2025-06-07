# Secure Go API with Kong (DB-Backed) and Keycloak

This project demonstrates a complete, production-ready setup for securing a Go backend API using **Kong** as an API Gateway in **DB-Backed Mode** and Keycloak for identity and access management.

Running Kong with a database is the standard approach for production environments that require dynamic configuration, high availability, and the ability to manage the gateway via its Admin API. This setup uses Kong's built-in `jwt` plugin for maximum stability and performance.

## Architecture & Flow

The runtime architecture uses Kong to protect the backend service. All configuration is applied dynamically to Kong's database via its Admin API after startup.

```mermaid
sequenceDiagram
    participant Client
    participant Kong Gateway (:8081)
    participant Keycloak (:8080)
    participant Go App (:3000)
    participant Kong Admin API (:8001)
    participant Kong DB

    Note over Client, Go App: Initial Setup
    activate Kong Admin API
    Admin Script->>Kong Admin API: POST /services (Create go-app-service)
    Kong Admin API->>Kong DB: Store service
    Admin Script->>Kong Admin API: POST /routes (Create /profile)
    Kong Admin API->>Kong DB: Store route
    Admin Script->>Kong Admin API: POST /plugins (Enable JWT)
    Kong Admin API->>Kong DB: Store plugin config
    Admin Script->>Kong Admin API: POST /consumers (Create keycloak-users)
    Kong Admin API->>Kong DB: Store consumer
    Admin Script->>Keycloak: GET /certs (Fetch public key)
    Keycloak-->>Admin Script: JWKS Data
    Admin Script->>Kong Admin API: POST /consumers/keycloak-users/jwt (Add public key)
    Kong Admin API->>Kong DB: Store JWT secret
    deactivate Kong Admin API
    
    Note over Client, Go App: Runtime Request
    Client->>+Keycloak: Request token (user: alice, pass: ...)
    Keycloak-->>-Client: JWT

    Client->>+Kong Gateway: GET /profile (Authorization: Bearer JWT)
    
    Note over Kong Gateway: Validate JWT using stored public key
    Note over Kong Gateway: JWT is valid!

    Kong Gateway->>+Go App: GET /profile (Forward request)
    Go App-->>-Kong Gateway: 200 OK ({"message":"Hello, alice", ...})
    Kong Gateway-->>-Client: 200 OK ({"message":"Hello, alice", ...})
```

## How to Run

1.  **Clean up previous volumes (Important for a fresh start):**
    ```powershell
    docker-compose down -v
    ```

2.  **Build and start all services:**
    The `--build` flag is only needed if you change your Go application's `Dockerfile`.
    ```powershell
    docker-compose up --build -d
    ```
    This command will start all services. The containers will start up in the correct order based on the `depends_on` configuration.

3.  **Wait for all services to initialize.**
    This is a critical step. Wait about **60-90 seconds** after the command finishes to ensure Keycloak and Kong are fully ready. You can monitor the status with `docker-compose ps`.

4.  **Configure Kong automatically:**
    In your PowerShell terminal, run the provided configuration script. This script will wait for the Admin API to be ready and then apply all necessary settings.
    ```powershell
    .\configure-kong.ps1
    ```
    You should see output confirming that the service, routes, and credentials were created successfully.

## Testing the Endpoints

After the configuration script has run, your gateway is ready to test.

1.  **Get a Token for `alice`:**
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

2.  **Test the Public Endpoint (succeeds):**
    ```powershell
    curl http://localhost:8081/public
    ```

3.  **Test the Profile Endpoint (succeeds):**
    ```powershell
    curl -H "Authorization: Bearer $token" http://localhost:8081/profile
    ```

4.  **Test without a Token (fails):**
    ```powershell
    curl -v http://localhost:8081/profile
    # Expected Output: HTTP/1.1 401 Unauthorized
    ```

## Deep Dive: Kong Configuration with the `jwt` Plugin

This project uses Kong's stable, **built-in `jwt` plugin**. This avoids the fragility of community plugins. The configuration is applied via API calls:

1.  **Service and Routes:** We first define the `go-app-service` and its associated URL paths (`/public`, `/profile`).

2.  **Enable the `jwt` Plugin:** We apply the `jwt` plugin to the entire `go-app-service`. This means, by default, all routes on that service will require a valid JWT.

3.  **Create a `Consumer`:** A Kong `Consumer` is an identity that we can associate credentials with. We create a generic `keycloak-users` consumer to represent all users coming from our Keycloak realm.

4.  **Register the Public Key:** This is the most important step. We make an API call to `/consumers/keycloak-users/jwt` and provide Keycloak's public key.
    *   The `key` field is set to the Keycloak token's `kid` (Key ID). When Kong sees an incoming JWT, it looks at the `kid` in the token's header and finds the matching credential we registered.
    *   The `rsa_public_key` is the actual public key used to verify the token's signature.

This setup securely configures Kong to trust JWTs issued by your Keycloak instance without needing any custom code in the gateway itself.