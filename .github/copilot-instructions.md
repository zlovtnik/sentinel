# Process Sentinel - AI Agent Instructions

## Architecture Overview

Process Sentinel is a **Zig 0.13+** microservice bridging **Oracle Advanced Queuing (AQ)** with real-time process monitoring. Key components:

```
┌─ src/main.zig          # Entry point, signal handling, component orchestration
├─ src/oracle/           # ODPI-C database layer (connection pool, AQ listener, bulk DML)
├─ src/api/              # HTTP server (std.net.Server), REST handlers
├─ src/worker/           # Thread pool for concurrent Oracle operations
├─ src/security/         # JWT (Keycloak), mTLS, multi-tenant isolation
├─ src/telemetry/        # Prometheus metrics, OpenTelemetry tracing
└─ sql/                  # PL/SQL migrations (sentinel_pkg API)
```

The **data flow**: Oracle packages → AQ enqueue → Sentinel dequeues via ODPI-C → worker pool processes → bulk inserts logs.

## Build & Development

```bash
make deps          # Clone ODPI-C to deps/odpi (one-time)
make build         # Debug build (requires ORACLE_HOME)
make release       # ReleaseFast build
make test          # Run tests (needs Oracle connection)
make check         # Fast syntax check (no Oracle required)
make fmt           # Format Zig source
make dev           # Watch mode (requires entr)
```

**Critical environment variables** (see [src/config/env.zig](src/config/env.zig)):
- `ORACLE_HOME` - Oracle Instant Client path
- `ORACLE_WALLET_LOCATION`, `ORACLE_TNS_NAME` - Wallet auth (no passwords in env)
- `OAUTH2_ISSUER_URI`, `OAUTH2_JWK_SET_URI` - Keycloak endpoints

## Code Conventions

### ODPI-C Integration Pattern
All Oracle calls go through [src/c_imports.zig](src/c_imports.zig) which wraps raw C types:
```zig
const dpi = @import("../c_imports.zig");
const c = dpi.c;  // Raw C namespace
// Use dpi.DpiConn, dpi.getErrorInfo() for Zig-friendly wrappers
```

### Error Handling
- ODPI-C calls return `< 0` on failure; always check and call `dpi.getErrorInfo(context)`
- Use Zig error unions (`!T`) for all fallible operations
- Connection pool tracks `error_count` atomically for observability

### Thread Safety
- All shared state uses `std.atomic.Value(T)` (see [connection.zig](src/oracle/connection.zig))
- Worker pool uses mutex-protected `TaskQueue` with condition variables
- Use `defer pool.release(conn)` pattern for connection lifecycle

### Multi-Tenancy
Tenant isolation is enforced at every layer:
- JWT claims extract `tenant_id` from Keycloak tokens
- All SQL queries filter by `tenant_id` (see [handlers.zig](src/api/handlers.zig))
- Oracle VPD policies supplement application-level checks

### Memory Management
- Use arena allocators for per-request memory in worker tasks
- Caller owns memory for parsed structures (see `Claims.deinit()` in [jwt.zig](src/security/jwt.zig))
- Avoid allocations in hot paths; prefer stack buffers or pre-allocated pools

## Oracle Specifics

### SQL Migrations
Run in order: `sql/001_*.sql` → `002` → `003` → `004`. The `sentinel_pkg` provides the PL/SQL SDK used by CLM Service.

### Bulk Insert Pattern
Array DML for high-throughput logging ([bulk_insert.zig](src/oracle/bulk_insert.zig)):
- Buffer entries locally, flush when batch size reached
- Uses `dpiConn_newVar` with array size for bind variables

### Queue Listener
AQ dequeue with configurable wait timeout; matches `sentinel_event_t` Oracle object type.

## Testing

Tests require a running Oracle database with wallet configured:
```bash
export ORACLE_WALLET_LOCATION=/path/to/wallet
zig build test
```

For syntax-only validation without Oracle: `make check`

## Docker & K8s

- Multi-stage [Dockerfile](Dockerfile): Zig 0.13 + Oracle Instant Client
- Kubernetes manifests in [k8s/](k8s/): 3-replica deployment, RBAC, ConfigMap for env vars
- Runs as non-root user (UID 1000)
