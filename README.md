# Secure Go Backend API with Kong and Keycloak

This project demonstrates a complete, production-ready setup for securing a Backend API using **Kong** as an API Gateway and **Keycloak** for identity and access management.

This final version uses a best-practice approach where **all** traffic, including authentication requests, is proxied through the Kong gateway. Kong's configuration is applied dynamically and automatically via a robust script.

## Architecture

In this secure architecture, the **only** entry point for external traffic is the Kong Gateway. The Backend API and Keycloak are isolated within the internal Docker network.

```
+--------+            +-------------------+      +-----------------+
|        |----------->|                   |----->| Keycloak        |
| Client |            |   Kong Gateway    |<-----| (for /auth/...) |
|        |            |   (Port :8081)    |      +-----------------+
|        |<---------- |                   |
+--------+            |  - JWT Validation |      +-----------------+
                      |  - Routing        |----->|  Backend API |
                      |                   |<-----| (for API calls) |
                      |                   |      +-----------------+
                      +-------------------+
```

1.  A **Client** requests a JWT from the Kong Gateway's `/auth` endpoint.  
2.  **Kong** forwards this request to the internal **Keycloak** instance.  
3.  Keycloak returns a JWT to the client, proxied back through Kong.  
4.  The Client then makes a request to a protected API endpoint (e.g., `/profile`) on the Kong Gateway, including the JWT.  
5.  **Kong** intercepts the request, and its `jwt` plugin validates the token's signature using Keycloak's public key.  
6.  If valid, Kong forwards the request to the upstream **Backend API**.  
7.  The **Backend API** trusts the request and processes it.

## Request Flow Diagram

```mermaid
sequenceDiagram
    participant Client
    participant Kong Gateway
    participant Keycloak
    participant Backend API

    Note over Client, Keycloak: Step 1: Client gets a token via the Gateway
    Client->>+Kong Gateway: POST /auth/.../token (Get Token)
    Kong Gateway->>+Keycloak: POST /realms/.../token (Forward Request)
    Keycloak-->>-Kong Gateway: JWT
    Kong Gateway-->>-Client: JWT

    Note over Client, Backend API: Step 2: Client uses token to access protected API
    Client->>+Kong Gateway: GET /profile (Authorization: Bearer JWT)
    
    Note over Kong Gateway: JWT Plugin validates token → OK

    Kong Gateway->>+Backend API: GET /profile (Forward Request)
    Backend API-->>-Kong Gateway: 200 OK ({"message":"Hello, alice", ...})
    Kong Gateway-->>-Client: 200 OK ({"message":"Hello, alice", ...})
````

## Project Structure

```
.
├── docker-compose.yml        # Main orchestrator for all services
├── Dockerfile                # For the Backend API application
├── Dockerfile.kong           # Custom Kong (with curl) Dockerfile
├── configure-kong.ps1        # Windows script to configure Kong
├── configure-kong.sh         # Linux/macOS script to configure Kong
├── go.mod                    
├── go.sum
├── main.go                   # Go backend application source code
├── test-all.ps1              # PowerShell automated test script
├── test-all.sh               # Linux/macOS automated test script
└── keycloak/
    └── import-realm.json     # Keycloak realm, user, and client definitions
```

## Prerequisites

* [Docker](https://www.docker.com/get-started) & [Docker Compose](https://docs.docker.com/compose/install/)
* **For Linux/macOS users:** You must have `curl`, `jq`, and `openssl` installed.

## How to Run

1. **Clean up previous volumes (Important):**

   ```bash
   docker-compose down -v
   ```

2. **Build and start all services:**

   ```bash
   docker-compose up --build -d
   ```

3. **Wait for all services to initialize (critical step):**
   Wait about **60–90 seconds**. You can monitor the status with:

   ```bash
   docker-compose ps
   ```

4. **Configure Kong automatically using the correct script for your OS:**

   * **On Windows (PowerShell):**

     ```powershell
     .\configure-kong.ps1
     ```
   * **On Linux or macOS (Bash/Shell):**

     ```bash
     chmod +x configure-kong.sh
     ./configure-kong.sh
     ```

   You should see output confirming that the services, routes, and JWT credentials were created successfully.

## Available Users

The `keycloak/import-realm.json` file creates two users for testing:

| Username | Password      | Roles   |
| :------- | :------------ | :------ |
| `alice`  | `password123` | `user`  |
| `bob`    | `password123` | `admin` |

## Testing

### Manual Testing

#### 1. Get an Access Token for `alice`

- **Windows (PowerShell):**
  ```powershell
  $resp = Invoke-RestMethod -Method Post `
    -Uri http://localhost:8081/auth/realms/demo-realm/protocol/openid-connect/token `
    -ContentType "application/x-www-form-urlencoded" `
    -Body @{ grant_type='password'; client_id='fiber-app'; username='alice'; password='password123' }
  $aliceToken = $resp.access_token
  ```

- **Linux/macOS (Bash):**

  ```bash
  aliceToken=$(curl -s -X POST http://localhost:8081/auth/realms/demo-realm/protocol/openid-connect/token \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "grant_type=password&client_id=fiber-app&username=alice&password=password123" \
    | jq -r .access_token)
  echo "Alice token: $aliceToken"
  ```

#### 2. Get an Access Token for `bob`

* **Windows (PowerShell):**

  ```powershell
  $resp2 = Invoke-RestMethod -Method Post `
    -Uri http://localhost:8081/auth/realms/demo-realm/protocol/openid-connect/token `
    -ContentType "application/x-www-form-urlencoded" `
    -Body @{ grant_type='password'; client_id='fiber-app'; username='bob'; password='password123' }
  $bobToken = $resp2.access_token
  ```

* **Linux/macOS (Bash):**

  ```bash
  bobToken=$(curl -s -X POST http://localhost:8081/auth/realms/demo-realm/protocol/openid-connect/token \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "grant_type=password&client_id=fiber-app&username=bob&password=password123" \
    | jq -r .access_token)
  echo "Bob token: $bobToken"
  ```

#### 3. Test Public Endpoint (`/public`)

* **Both:**

  ```bash
  curl http://localhost:8081/public
  # Expected: {"message":"This is a public endpoint."}
  ```

#### 4. Test Profile Endpoint (`/profile`)

* **With token:**

  * *PowerShell*:

    ```powershell
    curl -H "Authorization: Bearer $aliceToken" http://localhost:8081/profile
    ```

  * *Bash*:

    ```bash
    curl -H "Authorization: Bearer $aliceToken" http://localhost:8081/profile
    ```

* **Without token (should return 401):**

  * *PowerShell*:

    ```powershell
    curl -v http://localhost:8081/profile
    ```

  * *Bash*:

    ```bash
    curl -v http://localhost:8081/profile
    ```

#### 5. Test User-Level Endpoint (`/user`)

* **As `alice` (should succeed):**

  ```bash
  curl -H "Authorization: Bearer $aliceToken" http://localhost:8081/user
  ```

* **As `bob` (should return 403):**

  ```bash
  curl -H "Authorization: Bearer $bobToken" http://localhost:8081/user
  ```

#### 6. Test Admin-Level Endpoint (`/admin`)

* **As `alice` (should return 403):**

  ```bash
  curl -H "Authorization: Bearer $aliceToken" http://localhost:8081/admin
  ```

* **As `bob` (should succeed):**

  ```bash
  curl -H "Authorization: Bearer $bobToken" http://localhost:8081/admin
  ```

### Automated Script Testing

After manual verification, run:

* **Windows (PowerShell):**

  ```powershell
  .\test-all-kong.ps1
  ```
* **Linux/macOS (Bash):**

  ```bash
  chmod +x test-all-kong.sh
  ./test-all-kong.sh
  ```


The script will:

1. Verify Kong’s Admin API and service definitions.
2. Fetch JWKS through the Kong proxy.
3. Acquire JWTs for `alice` and `bob`.
4. Test `/public`, `/profile`, `/user`, and `/admin` endpoints in sequence.
5. Report success or failure for each step.

---

## Deep Dive: The Configuration Explained

### 1. Keycloak (`keycloak/import-realm.json`)

* **Realm Roles Mapper:** We add a protocol mapper to push realm roles into a top-level `roles` claim (multi-valued) in the JWT. This simplifies role extraction in our Backend API application.

### 2. Kong (configured via script)

* **Proxied Keycloak:** A service `keycloak-svc` and route `/auth` proxy authentication traffic to Keycloak.
* **Route-Based Security:** The `jwt` plugin is attached only to `/profile`, `/user`, and `/admin`.
* **Public Key Handling:** We fetch the JWK via the Kong proxy and convert it to PEM for Kong’s JWT plugin.

### 3. Backend API (`main.go`)

* **Trust the Gateway:** JWT signature validation is removed from the Backend API; Kong guarantees authenticity.
* **Authorization:** The Backend API parses the token’s `roles` claim and enforces role checks on `/user` and `/admin`.
* **Data Access:** The `/admin` endpoint also performs a MongoDB query to demonstrate a protected database operation.

