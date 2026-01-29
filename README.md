# Process Sentinel

Oracle-Zig Microservice for Real-Time Process Monitoring in the CLM Service Ecosystem.

## Overview

Process Sentinel is a high-performance Zig microservice that provides:

- **Real-time process monitoring** via Oracle Advanced Queuing (AQ)
- **RESTful HTTP API** for process status queries
- **Bulk logging** with array DML for high-throughput inserts
- **Multi-tenant isolation** with row-level security
- **Prometheus metrics** for observability
- **OpenTelemetry tracing** for distributed debugging

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                     Process Sentinel                                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │  HTTP API    │  │ AQ Listener  │  │ Worker Pool  │              │
│  │  Server      │  │ (Dequeue)    │  │ (Processing) │              │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘              │
│         │                 │                 │                       │
│  ┌──────┴─────────────────┴─────────────────┴───────┐              │
│  │              Connection Pool                       │              │
│  │           (ODPI-C / Oracle Wallet)                │              │
│  └────────────────────────┬──────────────────────────┘              │
└───────────────────────────┼─────────────────────────────────────────┘
                            │
                    ┌───────┴───────┐
                    │  Oracle 19c+  │
                    │  SENTINEL_*   │
                    └───────────────┘
```

## Prerequisites

- **Zig 0.13.0+** - [Install Zig](https://ziglang.org/download/)
- **Oracle Instant Client 21.x** - [Download](https://www.oracle.com/database/technologies/instant-client/downloads.html)
- **Oracle Database 19c+** with AQ enabled
- **Keycloak** (or compatible OIDC provider) for JWT authentication

## Project Structure

```
sentinel/
├── build.zig              # Build configuration
├── build.zig.zon          # Package manifest
├── Dockerfile             # Multi-stage Docker build
├── src/
│   ├── main.zig           # Entry point
│   ├── c_imports.zig      # ODPI-C bindings
│   ├── config/            # Configuration modules
│   │   ├── app.zig
│   │   ├── env.zig
│   │   └── wallet.zig
│   ├── oracle/            # Oracle database layer
│   │   ├── connection.zig
│   │   ├── queue.zig
│   │   ├── types.zig
│   │   └── bulk_insert.zig
│   ├── worker/            # Worker pool
│   │   ├── pool.zig
│   │   ├── arena.zig
│   │   └── task.zig
│   ├── api/               # HTTP API
│   │   ├── server.zig
│   │   ├── routes.zig
│   │   └── handlers.zig
│   ├── security/          # Security layer
│   │   ├── jwt.zig
│   │   ├── tls.zig
│   │   └── tenant.zig
│   └── telemetry/         # Observability
│       ├── metrics.zig
│       ├── tracing.zig
│       └── health.zig
├── sql/                   # Database migrations
│   ├── 001_sentinel_types.sql
│   ├── 002_sentinel_tables.sql
│   ├── 003_sentinel_queue.sql
│   └── 004_sentinel_pkg.sql
└── k8s/                   # Kubernetes manifests
    ├── namespace.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── configmap.yaml
    └── rbac.yaml
```

## Quick Start

### 1. Setup Oracle Database

Run the SQL migrations in order:

```bash
sqlplus system/password@//host:1521/service @sql/001_sentinel_types.sql
sqlplus system/password@//host:1521/service @sql/002_sentinel_tables.sql
sqlplus system/password@//host:1521/service @sql/003_sentinel_queue.sql
sqlplus system/password@//host:1521/service @sql/004_sentinel_pkg.sql
```

### 2. Configure Oracle Wallet

Create an auto-login wallet with database credentials:

```bash
mkstore -wrl /path/to/wallet -create
mkstore -wrl /path/to/wallet -createCredential SENTINEL_DB username password
```

### 3. Set Environment Variables

```bash
export ORACLE_WALLET_LOCATION=/path/to/wallet
export ORACLE_CONNECT_STRING=SENTINEL_DB
export SENTINEL_LISTEN_PORT=8080
export OAUTH2_ISSUER=https://keycloak.example.com/realms/clm
export OAUTH2_AUDIENCE=clm-api
```

### 4. Build and Run

```bash
# Build
zig build -Doptimize=ReleaseSafe

# Run
./zig-out/bin/sentinel
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `ORACLE_WALLET_LOCATION` | Path to Oracle Wallet | Required |
| `ORACLE_CONNECT_STRING` | TNS alias or connection string | Required |
| `SENTINEL_LISTEN_ADDRESS` | HTTP bind address | `0.0.0.0` |
| `SENTINEL_LISTEN_PORT` | HTTP port | `8080` |
| `SENTINEL_WORKER_THREADS` | Number of worker threads | `4` |
| `POOL_MIN_CONNECTIONS` | Minimum pool connections | `5` |
| `POOL_MAX_CONNECTIONS` | Maximum pool connections | `20` |
| `OAUTH2_ISSUER` | JWT issuer URL | Required |
| `OAUTH2_AUDIENCE` | JWT audience | Required |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Liveness probe |
| `GET` | `/ready` | Readiness probe |
| `GET` | `/metrics` | Prometheus metrics |
| `GET` | `/status/{process_id}` | Get process status |
| `GET` | `/processes` | List processes |
| `GET` | `/logs/{process_id}` | Get process logs |

## Docker Build

```bash
docker build -t sentinel:latest .
docker run -p 8080:8080 \
  -v /path/to/wallet:/opt/sentinel/wallet:ro \
  -e ORACLE_CONNECT_STRING=SENTINEL_DB \
  sentinel:latest
```

## Kubernetes Deployment

```bash
# Create namespace
kubectl apply -f k8s/namespace.yaml

# Create secrets (customize first!)
kubectl apply -f k8s/configmap.yaml

# Create Oracle wallet secret
kubectl create secret generic oracle-wallet \
  --from-file=cwallet.sso \
  --from-file=tnsnames.ora \
  -n clm-system

# Deploy
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

## Development

```bash
# Build in debug mode
zig build

# Run tests
zig build test

# Check for errors
zig build check

# Format code
zig fmt src/
```

## License

Proprietary - CLM System

## Version

0.1.0
