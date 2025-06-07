# Fiber + Keycloak + MongoDB Demo

A simple demo showing how to secure a Go Fiber API with Keycloak-issued JWTs, enforce realm-role-based access, and connect to MongoDB — **all traffic flows through Kong** as the API gateway.

---

## Table of Contents

- [Fiber + Keycloak + MongoDB Demo](#fiber--keycloak--mongodb-demo)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Architecture](#architecture)
  - [Prerequisites](#prerequisites)
  - [Project Structure](#project-structure)
  - [Configuration](#configuration)
    - [Environment Variables](#environment-variables)
  - [Getting Started](#getting-started)
    - [Clone \& Build](#clone--build)
    - [Install Go Dependencies](#install-go-dependencies)
    - [Run with Docker Compose](#run-with-docker-compose)
  - [API Endpoints (via Kong)](#api-endpoints-via-kong)
  - [Testing (through Kong)](#testing-through-kong)
    - [1. Obtain a JWT via Kong](#1-obtain-a-jwt-via-kong)
      - [Linux/macOS (bash)](#linuxmacos-bash)
      - [Windows (PowerShell)](#windows-powershell)
    - [2. Test Endpoints via Kong](#2-test-endpoints-via-kong)
      - [Linux/macOS (bash)](#linuxmacos-bash-1)
      - [Windows (PowerShell)](#windows-powershell-1)
  - [Contributing](#contributing)
  - [License](#license)

---

## Overview

This demo shows:

- A Go Fiber application exposing 4 endpoints  
- JWT validation via Keycloak’s JWKS endpoint  
- Role-based guards (`user` vs `admin`)  
- MongoDB integration to demonstrate a protected DB call  
- **All API traffic is proxied through Kong** on port **8000** (HTTP) or **8443** (HTTPS)

---

## Architecture

```mermaid
flowchart LR
    FiberApp["Fiber App<br>(port 3000)"]
    Kong["Kong<br>(8000/8443)"]
    Keycloak["Keycloak Auth<br>(8080)"]
    MongoDB["MongoDB<br>(27017)"]
    HTTPClient["HTTP Client<br>(curl, etc)"]

    FiberApp <--> Keycloak
    Kong <--> Keycloak
    FiberApp --> MongoDB
    Kong --> HTTPClient
````

---

## Prerequisites

* Docker & Docker Compose v2+
* Go toolchain (optional, only if you modify `main.go`)
* `curl`, `jq`, or any HTTP client for testing
* PowerShell (on Windows) for the PS examples

---

## Project Structure

```
.
├── Dockerfile              # Builds the Fiber app
├── docker-compose.yml      # Orchestrates mongo, keycloak, kong, app
├── keycloak/
│   └── import-realm.json   # Demo realm + users + roles + client
├── kong/
│   └── kong.yml            # Kong declarative config (JWT plugin, consumers)
└── main.go                 # Fiber application entrypoint
```

---

## Configuration

### Environment Variables

| Name              | Default                                   | Purpose                                    |
| ----------------- | ----------------------------------------- | ------------------------------------------ |
| `MONGO_URI`       | `mongodb://localhost:27017`               | MongoDB connection URI                     |
| `MONGO_DB`        | `demo_db`                                 | MongoDB database name                      |
| `KEYCLOAK_ISSUER` | `http://localhost:8080/realms/demo-realm` | Base URL for Keycloak realm (for JWKS URL) |
| `KONG_URL`        | `http://localhost:8000`                   | Kong gateway base URL for testing          |

---

## Getting Started

### Clone & Build

```bash
git clone https://github.com/your-org/fiber-keycloak-mongo-demo.git
cd fiber-keycloak-mongo-demo
```

*No need to build Go code locally unless you change `main.go`. Docker Compose will handle it.*

### Install Go Dependencies

```bash

go mod tidy

```

### Run with Docker Compose

```bash
docker-compose up --build
```

This starts MongoDB, Keycloak, Kong, and the Fiber app (behind Kong).

---

## API Endpoints (via Kong)

*All requests go through Kong at **`http://localhost:8000`** (or HTTPS on 8443).*

| Method | Path       | Auth                               | Description                    |
| ------ | ---------- | ---------------------------------- | ------------------------------ |
| GET    | `/public`  | None                               | Public endpoint                |
| GET    | `/profile` | Bearer JWT                         | Any authenticated user         |
| GET    | `/user`    | Bearer JWT with realm-role `user`  | User-level protected endpoint  |
| GET    | `/admin`   | Bearer JWT with realm-role `admin` | Admin-level protected endpoint |

---

## Testing (through Kong)

### 1. Obtain a JWT via Kong

#### Linux/macOS (bash)

```bash
# Alice (role "user")
export TOKEN=$(
  curl -s -X POST http://localhost:8000/realms/demo-realm/protocol/openid-connect/token \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&client_id=fiber-app&username=alice&password=password123" \
    | jq -r .access_token
)

# Bob (role "admin")
export ADMIN_TOKEN=$(
  curl -s -X POST http://localhost:8000/realms/demo-realm/protocol/openid-connect/token \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&client_id=fiber-app&username=bob&password=password123" \
    | jq -r .access_token
)
```

#### Windows (PowerShell)

```powershell
# Alice (role "user")
$TOKEN = (Invoke-RestMethod -Method Post `
  -Uri http://localhost:8000/realms/demo-realm/protocol/openid-connect/token `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{
    grant_type  = 'password'
    client_id   = 'fiber-app'
    username    = 'alice'
    password    = 'password123'
  }).access_token

# Bob (role "admin")
$ADMIN_TOKEN = (Invoke-RestMethod -Method Post `
  -Uri http://localhost:8000/realms/demo-realm/protocol/openid-connect/token `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{
    grant_type  = 'password'
    client_id   = 'fiber-app'
    username    = 'bob'
    password    = 'password123'
  }).access_token
```

### 2. Test Endpoints via Kong

#### Linux/macOS (bash)

```bash
# Public
curl http://localhost:8000/public

# Profile
curl http://localhost:8000/profile \
  -H "Authorization: Bearer $TOKEN"

# User endpoint
curl http://localhost:8000/user \
  -H "Authorization: Bearer $TOKEN"

# Admin endpoint
curl http://localhost:8000/admin \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

#### Windows (PowerShell)

```powershell
# Public
Invoke-RestMethod -Uri http://localhost:8000/public

# Profile
Invoke-RestMethod -Uri http://localhost:8000/profile `
  -Headers @{ Authorization = "Bearer $TOKEN" }

# User endpoint
Invoke-RestMethod -Uri http://localhost:8000/user `
  -Headers @{ Authorization = "Bearer $TOKEN" }

# Admin endpoint
Invoke-RestMethod -Uri http://localhost:8000/admin `
  -Headers @{ Authorization = "Bearer $ADMIN_TOKEN" }
```

**Expected status codes:**

* `/public`: **200 OK**
* `/profile`: **200 OK**
* `/user`: **200 OK** for Alice, **403 Forbidden** otherwise
* `/admin`: **200 OK** for Bob, **403 Forbidden** otherwise

---

## Contributing

1. Fork the repo
2. Create a feature branch
3. Commit & push your changes
4. Open a pull request

*Please format Go code with `go fmt` and add tests for new behavior.*

---

## License

MIT © Palakorn Voramongkol


