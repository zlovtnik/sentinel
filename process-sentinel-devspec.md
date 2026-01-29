# Oracle-Zig Process Sentinel - Development Specification

## Executive Summary

The **Process Sentinel** is a high-performance, memory-safe microservice written in **Zig 0.13.0+** that provides real-time process monitoring, event streaming, and telemetry aggregation for the CLM Service ecosystem. It bridges Oracle's Advanced Queuing (AQ) with external systems via a zero-copy, arena-allocated architecture.

### Integration with CLM Service

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        CLM Service (Spring Boot)                        │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────────────┐ │
│  │ Camel Routes │  │  Services    │  │  Oracle Repositories           │ │
│  │  (ETL/Integ) │──│  (Contract,  │──│  (SimpleJdbcCall, STRUCT/ARRAY)│ │
│  └──────────────┘  │   Customer)  │  └────────────────────────────────┘ │
│                    └──────────────┘                                     │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ JDBC (mTLS via Wallet)
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        Oracle 19c/21c Database                          │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────────────────┐ │
│  │ CONTRACT_PKG   │  │ INTEGRATION_PKG │  │ SENTINEL_PKG (NEW)        │ │
│  │ CUSTOMER_PKG   │  │ ETL_PKG         │  │ - start_process()         │ │
│  │                │  │                 │  │ - log_event()             │ │
│  │                │  │                 │  │ - notify_sentinel()       │ │
│  └────────────────┘  └────────────────┘  └─────────────┬──────────────┘ │
│                                                         │ AQ Enqueue    │
│  ┌──────────────────────────────────────────────────────▼─────────────┐ │
│  │  SENTINEL_QUEUE (Oracle AQ)                                        │ │
│  │  - Process events, heartbeats, completions, errors                 │ │
│  └──────────────────────────────────────────────────────┬─────────────┘ │
│                                                         │ Dequeue       │
└─────────────────────────────────────────────────────────┼───────────────┘
                                                          │ ODPI-C (mTLS)
                                                          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    Process Sentinel (Zig 0.13.0+)                       │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │ AQ Listener      │  │ Thread Pool      │  │ HTTP Server          │  │
│  │ (dpiConn_dequeue)│──│ (DB Workers)     │  │ (std.net.Server)     │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────────┘  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │ Arena Allocator  │  │ Connection Pool  │  │ Metrics Collector    │  │
│  │ (Per-Request)    │  │ (Persistent OCI) │  │ (Prometheus/OTEL)    │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 1. Security Architecture

### 1.1 Mutual TLS (mTLS) with Oracle Wallet

The Sentinel **MUST** use the same Oracle Wallet infrastructure as CLM Service for database connectivity.

```
SECURITY_REQUIREMENTS:
├── Oracle Wallet (.sso files) - NO password exposure
├── TLS 1.3 minimum for all connections
├── Certificate pinning for Oracle endpoints
├── JWT validation for API consumers (shared Keycloak realm)
└── Tenant isolation at all layers
```

**Wallet Configuration** (shared with CLM Service):

```zig
// src/config/wallet.zig
const WalletConfig = struct {
    wallet_location: []const u8,  // $ORACLE_WALLET_LOCATION
    tns_name: []const u8,         // $ORACLE_TNS_NAME
    ssl_server_dn_match: bool = true,
    
    pub fn getConnectionDescriptor(self: WalletConfig) []const u8 {
        // Build connection descriptor matching CLM Service format:
        // (description=(retry_count=20)(retry_delay=3)
        //   (address=(protocol=tcps)(port=1522)(host=...))
        //   (connect_data=(service_name=...))
        //   (security=(ssl_server_dn_match=yes)))
    }
};
```

### 1.2 Authentication Matrix

| Consumer          | Auth Method          | Token Source           |
|-------------------|----------------------|------------------------|
| CLM Service       | mTLS + Service Token | Keycloak Client Creds  |
| External APIs     | JWT Bearer           | Keycloak User Token    |
| Oracle AQ         | Wallet (Auto-login)  | cwallet.sso            |
| Metrics Scraper   | mTLS Client Cert     | PKI Infrastructure     |

### 1.3 JWT Validation (Keycloak Integration)

```zig
// src/security/jwt.zig
const JwtValidator = struct {
    jwk_set_uri: []const u8,      // Same as OAUTH2_JWK_SET_URI
    issuer: []const u8,            // Same as OAUTH2_ISSUER_URI
    audience: []const u8 = "clm-service",
    tenant_claim: []const u8 = "tenant_id",
    roles_claim: []const u8 = "roles",
    
    pub fn validate(self: *JwtValidator, token: []const u8) !Claims {
        // 1. Fetch JWKS from Keycloak (cached, TTL 5m)
        // 2. Verify RS256 signature
        // 3. Validate exp, iat, iss, aud
        // 4. Extract tenant_id for row-level isolation
    }
};
```

---

## 2. Core Engine Specification

### 2.1 Technology Stack

| Component         | Technology          | Version   | Purpose                     |
|-------------------|---------------------|-----------|------------------------------|
| Language          | Zig                 | 0.13.0+   | Memory safety, performance   |
| Oracle Driver     | ODPI-C              | 5.3+      | Native OCI wrapper           |
| HTTP Server       | std.net.Server      | stdlib    | Control plane API            |
| JSON              | std.json            | stdlib    | Config & payloads            |
| TLS               | std.crypto.tls      | stdlib    | Secure transport             |
| Logging           | Custom (OSON)       | -         | Binary Oracle JSON           |

### 2.2 Directory Structure

```
process-sentinel/
├── build.zig                 # Build configuration with Oracle linkage
├── build.zig.zon             # Dependencies (ODPI-C source)
├── src/
│   ├── main.zig              # Entry point, signal handlers
│   ├── c_imports.zig         # @cImport for dpi.h
│   ├── config/
│   │   ├── wallet.zig        # Oracle wallet configuration
│   │   ├── env.zig           # Environment variable loader
│   │   └── app.zig           # Application configuration
│   ├── security/
│   │   ├── jwt.zig           # Keycloak JWT validation
│   │   ├── tls.zig           # mTLS configuration
│   │   └── tenant.zig        # Multi-tenant isolation
│   ├── oracle/
│   │   ├── connection.zig    # ODPI-C connection pool
│   │   ├── queue.zig         # AQ dequeue operations
│   │   ├── bulk_insert.zig   # Array DML for logs
│   │   └── types.zig         # Oracle type mappings
│   ├── worker/
│   │   ├── pool.zig          # Thread pool for DB workers
│   │   ├── arena.zig         # Per-request arena allocator
│   │   └── task.zig          # Task definitions
│   ├── api/
│   │   ├── server.zig        # HTTP server
│   │   ├── routes.zig        # Endpoint definitions
│   │   └── handlers.zig      # Request handlers
│   └── telemetry/
│       ├── metrics.zig       # Prometheus-compatible metrics
│       ├── tracing.zig       # OpenTelemetry spans
│       └── health.zig        # Liveness/readiness probes
├── sql/
│   ├── 001_sentinel_types.sql
│   ├── 002_sentinel_tables.sql
│   ├── 003_sentinel_queue.sql
│   └── 004_sentinel_pkg.sql
└── test/
    ├── unit/
    └── integration/
```

### 2.3 Build System (build.zig)

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Oracle Instant Client paths (from environment)
    const oracle_home = std.posix.getenv("ORACLE_HOME") orelse 
        "/opt/oracle/instantclient_21_12";
    const odpic_path = std.posix.getenv("ODPIC_PATH") orelse 
        "deps/odpi";

    const exe = b.addExecutable(.{
        .name = "process-sentinel",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link ODPI-C (static)
    exe.addIncludePath(.{ .cwd_relative = odpic_path ++ "/include" });
    exe.addIncludePath(.{ .cwd_relative = odpic_path ++ "/src" });
    
    // Compile ODPI-C source files
    const odpi_sources = [_][]const u8{
        "dpiConn.c", "dpiContext.c", "dpiData.c", "dpiDeqOptions.c",
        "dpiEnqOptions.c", "dpiEnv.c", "dpiError.c", "dpiGen.c",
        "dpiGlobal.c", "dpiLob.c", "dpiMsgProps.c", "dpiObjectAttr.c",
        "dpiObjectType.c", "dpiObject.c", "dpiOracleType.c", "dpiPool.c",
        "dpiQueue.c", "dpiRowid.c", "dpiSodaColl.c", "dpiSodaDb.c",
        "dpiSodaDoc.c", "dpiSodaDocCursor.c", "dpiStmt.c", "dpiSubscr.c",
        "dpiUtils.c", "dpiVar.c", "dpiJson.c", "dpiVector.c",
    };

    for (odpi_sources) |src| {
        exe.addCSourceFile(.{
            .file = b.path(odpic_path ++ "/src/" ++ src),
            .flags = &.{"-std=c11", "-O3"},
        });
    }

    // Link Oracle Instant Client libraries
    exe.addLibraryPath(.{ .cwd_relative = oracle_home });
    exe.linkSystemLibrary("clntsh");
    exe.linkLibC();

    b.installArtifact(exe);

    // Test configuration
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

---

## 3. Database Schema (Abstract Persistence)

### 3.1 Core Tables

```sql
-- sql/002_sentinel_tables.sql

-- =============================================================================
-- PROCESS_REGISTRY: Master process catalog
-- =============================================================================
CREATE TABLE process_registry (
    process_id          VARCHAR2(100) PRIMARY KEY,
    process_uuid        RAW(16) DEFAULT SYS_GUID() NOT NULL UNIQUE,
    
    -- Classification
    process_type        VARCHAR2(50) NOT NULL,
    process_name        VARCHAR2(200) NOT NULL,
    package_name        VARCHAR2(128),   -- e.g., 'CONTRACT_PKG'
    procedure_name      VARCHAR2(128),   -- e.g., 'CREATE_CONTRACT'
    
    -- Ownership
    tenant_id           VARCHAR2(50) NOT NULL,
    owner_service       VARCHAR2(100) DEFAULT 'CLM_SERVICE',
    
    -- Lifecycle
    status              VARCHAR2(20) DEFAULT 'REGISTERED' NOT NULL,
    registered_at       TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    last_heartbeat_at   TIMESTAMP,
    expires_at          TIMESTAMP,
    
    -- Configuration
    config              JSON,  -- Oracle 21c native JSON type
    tags                JSON,
    
    -- Metrics
    total_executions    NUMBER DEFAULT 0,
    successful_runs     NUMBER DEFAULT 0,
    failed_runs         NUMBER DEFAULT 0,
    avg_duration_ms     NUMBER,
    
    CONSTRAINT chk_process_status CHECK (status IN (
        'REGISTERED', 'ACTIVE', 'RUNNING', 'PAUSED', 
        'COMPLETED', 'FAILED', 'EXPIRED', 'ARCHIVED'
    ))
) PARTITION BY LIST (tenant_id) AUTOMATIC (
    PARTITION p_default VALUES ('DEFAULT')
);

CREATE INDEX idx_process_tenant_status ON process_registry(tenant_id, status);
CREATE INDEX idx_process_package ON process_registry(package_name, procedure_name);
CREATE INDEX idx_process_heartbeat ON process_registry(last_heartbeat_at) LOCAL;

-- =============================================================================
-- PROCESS_LIVE_STATUS: Real-time status (GTT for speed, with persistent option)
-- =============================================================================
CREATE GLOBAL TEMPORARY TABLE process_live_status_gtt (
    process_id          VARCHAR2(100) PRIMARY KEY,
    status              VARCHAR2(20) NOT NULL,
    started_at          TIMESTAMP,
    current_step        VARCHAR2(200),
    progress_percent    NUMBER(5,2),
    last_update_at      TIMESTAMP DEFAULT SYSTIMESTAMP,
    metadata            JSON
) ON COMMIT PRESERVE ROWS;

-- Persistent mirror for queries across sessions
CREATE TABLE process_live_status (
    process_id          VARCHAR2(100) PRIMARY KEY,
    tenant_id           VARCHAR2(50) NOT NULL,
    status              VARCHAR2(20) NOT NULL,
    started_at          TIMESTAMP,
    current_step        VARCHAR2(200),
    progress_percent    NUMBER(5,2),
    last_update_at      TIMESTAMP DEFAULT SYSTIMESTAMP,
    estimated_completion TIMESTAMP,
    metadata            JSON,
    
    CONSTRAINT fk_live_process FOREIGN KEY (process_id)
        REFERENCES process_registry(process_id)
);

CREATE INDEX idx_live_status_tenant ON process_live_status(tenant_id, status);

-- =============================================================================
-- PROCESS_LOGS: High-volume logging with interval partitioning
-- =============================================================================
CREATE TABLE process_logs (
    log_id              NUMBER GENERATED ALWAYS AS IDENTITY,
    log_uuid            RAW(16) DEFAULT SYS_GUID(),
    
    -- Foreign keys
    process_id          VARCHAR2(100) NOT NULL,
    tenant_id           VARCHAR2(50) NOT NULL,
    
    -- Event classification
    log_level           VARCHAR2(10) NOT NULL,
    event_type          VARCHAR2(50),
    component           VARCHAR2(100),
    
    -- Content (OSON binary for performance in 21c)
    message             VARCHAR2(4000),
    details             JSON,       -- Use OSON storage
    stack_trace         CLOB,
    
    -- Timing
    logged_at           TIMESTAMP(6) DEFAULT SYSTIMESTAMP NOT NULL,
    event_duration_us   NUMBER,     -- Microseconds
    
    -- Correlation
    correlation_id      VARCHAR2(100),
    span_id             VARCHAR2(32),
    trace_id            VARCHAR2(32),
    
    CONSTRAINT chk_log_level CHECK (log_level IN (
        'TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'
    ))
) PARTITION BY RANGE (logged_at) INTERVAL (NUMTODSINTERVAL(1, 'DAY')) (
    PARTITION p_initial VALUES LESS THAN (TIMESTAMP '2026-01-01 00:00:00')
);

CREATE INDEX idx_logs_process_time ON process_logs(process_id, logged_at DESC) LOCAL;
CREATE INDEX idx_logs_tenant_level ON process_logs(tenant_id, log_level, logged_at DESC) LOCAL;
CREATE INDEX idx_logs_correlation ON process_logs(correlation_id) LOCAL;

-- Enable OSON (binary JSON) for optimal Zig integration
ALTER TABLE process_logs 
    MODIFY details JSON USING OSON;
```

### 3.2 Oracle Advanced Queuing Setup

```sql
-- sql/003_sentinel_queue.sql

-- =============================================================================
-- SENTINEL_QUEUE: Real-time event bus
-- =============================================================================

-- Queue payload type
CREATE OR REPLACE TYPE sentinel_event_t AS OBJECT (
    event_id        VARCHAR2(100),
    event_type      VARCHAR2(50),     -- STARTED, HEARTBEAT, PROGRESS, COMPLETED, ERROR
    process_id      VARCHAR2(100),
    tenant_id       VARCHAR2(50),
    timestamp_utc   TIMESTAMP,
    payload         CLOB              -- JSON payload
);
/

-- Create queue table
BEGIN
    DBMS_AQADM.CREATE_QUEUE_TABLE(
        queue_table        => 'SENTINEL_QUEUE_TAB',
        queue_payload_type => 'SENTINEL_EVENT_T',
        sort_list          => 'PRIORITY,ENQ_TIME',
        multiple_consumers => FALSE,
        message_grouping   => DBMS_AQADM.NONE,
        storage_clause     => 'TABLESPACE CLM_DATA
                              PCTFREE 10 PCTUSED 40
                              LOB(payload) STORE AS SECUREFILE (
                                  TABLESPACE CLM_DATA
                                  DISABLE STORAGE IN ROW
                                  COMPRESS HIGH
                              )'
    );
END;
/

-- Create the queue
BEGIN
    DBMS_AQADM.CREATE_QUEUE(
        queue_name   => 'SENTINEL_QUEUE',
        queue_table  => 'SENTINEL_QUEUE_TAB',
        max_retries  => 3,
        retry_delay  => 10,
        comment      => 'Process Sentinel real-time event queue'
    );
END;
/

-- Start the queue
BEGIN
    DBMS_AQADM.START_QUEUE(queue_name => 'SENTINEL_QUEUE');
END;
/

-- Grant access to CLM service user
GRANT EXECUTE ON sentinel_event_t TO clm_app;
GRANT EXECUTE ON DBMS_AQ TO clm_app;
BEGIN
    DBMS_AQADM.GRANT_QUEUE_PRIVILEGE(
        privilege    => 'ALL',
        queue_name   => 'SENTINEL_QUEUE',
        grantee      => 'CLM_APP'
    );
END;
/
```

### 3.3 Sentinel PL/SQL Package (Developer SDK)

```sql
-- sql/004_sentinel_pkg.sql

CREATE OR REPLACE PACKAGE sentinel_pkg AS
    -- ==========================================================================
    -- CONSTANTS
    -- ==========================================================================
    c_event_started     CONSTANT VARCHAR2(20) := 'STARTED';
    c_event_heartbeat   CONSTANT VARCHAR2(20) := 'HEARTBEAT';
    c_event_progress    CONSTANT VARCHAR2(20) := 'PROGRESS';
    c_event_completed   CONSTANT VARCHAR2(20) := 'COMPLETED';
    c_event_error       CONSTANT VARCHAR2(20) := 'ERROR';
    
    -- ==========================================================================
    -- PROCESS LIFECYCLE
    -- ==========================================================================
    
    -- Start monitoring a process (called at beginning of PL/SQL execution)
    PROCEDURE start_process(
        p_package_name    IN VARCHAR2,
        p_procedure_name  IN VARCHAR2 DEFAULT NULL,
        p_tenant_id       IN VARCHAR2 DEFAULT SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
        p_correlation_id  IN VARCHAR2 DEFAULT NULL,
        p_metadata        IN CLOB DEFAULT NULL,
        p_process_id      OUT VARCHAR2
    );
    
    -- Convenience overload: returns process_id directly
    FUNCTION start_proc(
        p_package_name    IN VARCHAR2,
        p_procedure_name  IN VARCHAR2 DEFAULT NULL,
        p_tenant_id       IN VARCHAR2 DEFAULT SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER')
    ) RETURN VARCHAR2;
    
    -- Update progress
    PROCEDURE update_progress(
        p_process_id      IN VARCHAR2,
        p_current_step    IN VARCHAR2,
        p_progress_pct    IN NUMBER DEFAULT NULL,
        p_metadata        IN CLOB DEFAULT NULL
    );
    
    -- Send heartbeat (call periodically in long-running processes)
    PROCEDURE heartbeat(
        p_process_id      IN VARCHAR2,
        p_status_message  IN VARCHAR2 DEFAULT NULL
    );
    
    -- Complete process successfully
    PROCEDURE complete_process(
        p_process_id      IN VARCHAR2,
        p_result          IN CLOB DEFAULT NULL
    );
    
    -- Mark process as failed
    PROCEDURE fail_process(
        p_process_id      IN VARCHAR2,
        p_error_code      IN VARCHAR2,
        p_error_message   IN VARCHAR2,
        p_stack_trace     IN CLOB DEFAULT NULL
    );
    
    -- ==========================================================================
    -- LOGGING
    -- ==========================================================================
    
    PROCEDURE log_debug(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL
    );
    
    PROCEDURE log_info(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL
    );
    
    PROCEDURE log_warn(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL
    );
    
    PROCEDURE log_error(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL,
        p_stack_trace IN CLOB DEFAULT NULL
    );
    
    -- Bulk log insertion (for performance)
    PROCEDURE flush_logs(
        p_process_id IN VARCHAR2
    );
    
    -- ==========================================================================
    -- INTERNAL: Queue operations
    -- ==========================================================================
    
    PROCEDURE notify_sentinel(
        p_event_type   IN VARCHAR2,
        p_process_id   IN VARCHAR2,
        p_tenant_id    IN VARCHAR2,
        p_payload      IN CLOB DEFAULT NULL
    );
    
END sentinel_pkg;
/

CREATE OR REPLACE PACKAGE BODY sentinel_pkg AS

    -- -------------------------------------------------------------------------
    -- start_process: Register and notify sentinel
    -- -------------------------------------------------------------------------
    PROCEDURE start_process(
        p_package_name    IN VARCHAR2,
        p_procedure_name  IN VARCHAR2 DEFAULT NULL,
        p_tenant_id       IN VARCHAR2 DEFAULT SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
        p_correlation_id  IN VARCHAR2 DEFAULT NULL,
        p_metadata        IN CLOB DEFAULT NULL,
        p_process_id      OUT VARCHAR2
    ) IS
        l_uuid RAW(16);
    BEGIN
        l_uuid := SYS_GUID();
        p_process_id := RAWTOHEX(l_uuid);
        
        -- Register in process_registry
        INSERT INTO process_registry (
            process_id, process_uuid, process_type, process_name,
            package_name, procedure_name, tenant_id, status
        ) VALUES (
            p_process_id, l_uuid, 'PLSQL_PROCEDURE', 
            p_package_name || '.' || NVL(p_procedure_name, '*'),
            p_package_name, p_procedure_name, 
            NVL(p_tenant_id, 'DEFAULT'), 'RUNNING'
        );
        
        -- Initialize live status
        INSERT INTO process_live_status (
            process_id, tenant_id, status, started_at, current_step
        ) VALUES (
            p_process_id, NVL(p_tenant_id, 'DEFAULT'), 
            'RUNNING', SYSTIMESTAMP, 'INITIALIZING'
        );
        
        -- Notify sentinel (async)
        notify_sentinel(c_event_started, p_process_id, p_tenant_id, p_metadata);
        
        COMMIT;
    END start_process;
    
    -- -------------------------------------------------------------------------
    -- start_proc: Convenience function
    -- -------------------------------------------------------------------------
    FUNCTION start_proc(
        p_package_name    IN VARCHAR2,
        p_procedure_name  IN VARCHAR2 DEFAULT NULL,
        p_tenant_id       IN VARCHAR2 DEFAULT SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER')
    ) RETURN VARCHAR2 IS
        l_process_id VARCHAR2(100);
    BEGIN
        start_process(
            p_package_name   => p_package_name,
            p_procedure_name => p_procedure_name,
            p_tenant_id      => p_tenant_id,
            p_process_id     => l_process_id
        );
        RETURN l_process_id;
    END start_proc;
    
    -- -------------------------------------------------------------------------
    -- notify_sentinel: Enqueue event to AQ
    -- -------------------------------------------------------------------------
    PROCEDURE notify_sentinel(
        p_event_type   IN VARCHAR2,
        p_process_id   IN VARCHAR2,
        p_tenant_id    IN VARCHAR2,
        p_payload      IN CLOB DEFAULT NULL
    ) IS
        l_enqueue_options    DBMS_AQ.ENQUEUE_OPTIONS_T;
        l_message_properties DBMS_AQ.MESSAGE_PROPERTIES_T;
        l_message_handle     RAW(16);
        l_event              sentinel_event_t;
    BEGIN
        l_event := sentinel_event_t(
            event_id      => SYS_GUID(),
            event_type    => p_event_type,
            process_id    => p_process_id,
            tenant_id     => NVL(p_tenant_id, 'DEFAULT'),
            timestamp_utc => SYS_EXTRACT_UTC(SYSTIMESTAMP),
            payload       => p_payload
        );
        
        -- Set priority based on event type
        l_message_properties.priority := 
            CASE p_event_type
                WHEN c_event_error THEN 1
                WHEN c_event_completed THEN 2
                WHEN c_event_started THEN 3
                ELSE 5
            END;
        
        DBMS_AQ.ENQUEUE(
            queue_name         => 'SENTINEL_QUEUE',
            enqueue_options    => l_enqueue_options,
            message_properties => l_message_properties,
            payload            => l_event,
            msgid              => l_message_handle
        );
    END notify_sentinel;
    
    -- [Additional procedure implementations...]
    
END sentinel_pkg;
/
```

---

## 4. Zig Implementation

### 4.1 C Imports (ODPI-C Bridge)

```zig
// src/c_imports.zig
pub const c = @cImport({
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cInclude("dpi.h");
});

// Type aliases for clarity
pub const DpiContext = c.dpiContext;
pub const DpiPool = c.dpiPool;
pub const DpiConn = c.dpiConn;
pub const DpiStmt = c.dpiStmt;
pub const DpiDeqOptions = c.dpiDeqOptions;
pub const DpiMsgProps = c.dpiMsgProps;
pub const DpiQueue = c.dpiQueue;

pub const DpiError = struct {
    code: i32,
    message: []const u8,
    fn_name: []const u8,
    action: []const u8,
    sql_state: [6]u8,
    is_recoverable: bool,
};

pub fn getErrorInfo(context: *DpiContext) DpiError {
    var err_info: c.dpiErrorInfo = undefined;
    c.dpiContext_getError(context, &err_info);
    return .{
        .code = err_info.code,
        .message = err_info.message[0..err_info.messageLength],
        .fn_name = err_info.fnName[0..std.mem.len(err_info.fnName)],
        .action = err_info.action[0..std.mem.len(err_info.action)],
        .sql_state = err_info.sqlState,
        .is_recoverable = err_info.isRecoverable != 0,
    };
}
```

### 4.2 Connection Pool

```zig
// src/oracle/connection.zig
const std = @import("std");
const c = @import("../c_imports.zig").c;
const WalletConfig = @import("../config/wallet.zig").WalletConfig;

pub const ConnectionPool = struct {
    context: *c.dpiContext,
    pool: *c.dpiPool,
    config: PoolConfig,
    
    pub const PoolConfig = struct {
        min_sessions: u32 = 2,
        max_sessions: u32 = 10,
        session_increment: u32 = 1,
        ping_interval: i32 = 60,
        timeout: i32 = 0,
        wait_timeout: u32 = 5000,
        max_lifetime_session: u32 = 3600,
        get_mode: c.dpiPoolGetMode = c.DPI_MODE_POOL_GET_TIMEDWAIT,
    };
    
    pub fn init(
        wallet: WalletConfig,
        username: []const u8,
        password: []const u8,
        pool_config: PoolConfig,
    ) !ConnectionPool {
        var context: *c.dpiContext = undefined;
        var err_info: c.dpiErrorInfo = undefined;
        
        // Create ODPI-C context
        if (c.dpiContext_createWithParams(
            c.DPI_MAJOR_VERSION,
            c.DPI_MINOR_VERSION,
            null,
            &context,
            &err_info,
        ) < 0) {
            return error.ContextCreationFailed;
        }
        
        // Build connection descriptor
        const conn_str = wallet.getConnectionDescriptor();
        
        // Pool creation parameters
        var create_params: c.dpiPoolCreateParams = undefined;
        _ = c.dpiContext_initPoolCreateParams(context, &create_params);
        
        create_params.minSessions = pool_config.min_sessions;
        create_params.maxSessions = pool_config.max_sessions;
        create_params.sessionIncrement = pool_config.session_increment;
        create_params.pingInterval = pool_config.ping_interval;
        create_params.pingTimeout = pool_config.timeout;
        create_params.getMode = pool_config.get_mode;
        create_params.timeout = pool_config.wait_timeout;
        create_params.maxLifetimeSession = pool_config.max_lifetime_session;
        
        var pool: *c.dpiPool = undefined;
        if (c.dpiPool_create(
            context,
            username.ptr, @intCast(username.len),
            password.ptr, @intCast(password.len),
            conn_str.ptr, @intCast(conn_str.len),
            null, // common params (use defaults)
            &create_params,
            &pool,
        ) < 0) {
            return error.PoolCreationFailed;
        }
        
        return .{
            .context = context,
            .pool = pool,
            .config = pool_config,
        };
    }
    
    pub fn acquire(self: *ConnectionPool) !*c.dpiConn {
        var conn: *c.dpiConn = undefined;
        if (c.dpiPool_acquireConnection(
            self.pool,
            null, 0,  // username (use pool credentials)
            null, 0,  // password
            null,     // connection params
            &conn,
        ) < 0) {
            return error.ConnectionAcquisitionFailed;
        }
        return conn;
    }
    
    pub fn release(self: *ConnectionPool, conn: *c.dpiConn) void {
        _ = self;
        _ = c.dpiConn_release(conn);
    }
    
    pub fn deinit(self: *ConnectionPool) void {
        _ = c.dpiPool_release(self.pool);
        _ = c.dpiContext_destroy(self.context);
    }
};
```

### 4.3 AQ Listener (Real-Time Dequeuer)

```zig
// src/oracle/queue.zig
const std = @import("std");
const c = @import("../c_imports.zig").c;
const ConnectionPool = @import("connection.zig").ConnectionPool;

pub const SentinelEvent = struct {
    event_id: []const u8,
    event_type: EventType,
    process_id: []const u8,
    tenant_id: []const u8,
    timestamp_utc: i64,
    payload: ?[]const u8,
    
    pub const EventType = enum {
        started,
        heartbeat,
        progress,
        completed,
        @"error",
        
        pub fn fromString(s: []const u8) ?EventType {
            const map = std.ComptimeStringMap(EventType, .{
                .{ "STARTED", .started },
                .{ "HEARTBEAT", .heartbeat },
                .{ "PROGRESS", .progress },
                .{ "COMPLETED", .completed },
                .{ "ERROR", .@"error" },
            });
            return map.get(s);
        }
    };
};

pub const QueueListener = struct {
    pool: *ConnectionPool,
    queue_name: []const u8,
    deq_options: *c.dpiDeqOptions,
    running: std.atomic.Value(bool),
    
    const DEQUEUE_WAIT_SECONDS: u32 = 5;
    
    pub fn init(pool: *ConnectionPool, queue_name: []const u8) !QueueListener {
        const conn = try pool.acquire();
        defer pool.release(conn);
        
        var deq_options: *c.dpiDeqOptions = undefined;
        if (c.dpiConn_newDeqOptions(conn, &deq_options) < 0) {
            return error.DeqOptionsCreationFailed;
        }
        
        // Configure dequeue options
        _ = c.dpiDeqOptions_setNavigation(deq_options, c.DPI_DEQ_NAV_FIRST_MSG);
        _ = c.dpiDeqOptions_setWait(deq_options, DEQUEUE_WAIT_SECONDS);
        _ = c.dpiDeqOptions_setVisibility(deq_options, c.DPI_VISIBILITY_ON_COMMIT);
        
        return .{
            .pool = pool,
            .queue_name = queue_name,
            .deq_options = deq_options,
            .running = std.atomic.Value(bool).init(true),
        };
    }
    
    pub fn listen(self: *QueueListener, handler: *const fn (SentinelEvent) void) !void {
        while (self.running.load(.seq_cst)) {
            const conn = try self.pool.acquire();
            defer self.pool.release(conn);
            
            var queue: *c.dpiQueue = undefined;
            if (c.dpiConn_newQueue(
                conn,
                self.queue_name.ptr, @intCast(self.queue_name.len),
                null, // object type (use default)
                &queue,
            ) < 0) {
                std.time.sleep(std.time.ns_per_s);
                continue;
            }
            defer _ = c.dpiQueue_release(queue);
            
            var msg_props: *c.dpiMsgProps = undefined;
            var msg: *c.dpiObject = undefined;
            
            const result = c.dpiQueue_deqOne(queue, &msg_props, &msg);
            
            if (result < 0) {
                // Timeout or empty queue - continue polling
                continue;
            }
            
            if (msg != null) {
                const event = self.parseEvent(msg) catch |err| {
                    std.log.err("Failed to parse event: {}", .{err});
                    continue;
                };
                
                handler(event);
                
                // Commit dequeue
                _ = c.dpiConn_commit(conn);
            }
        }
    }
    
    fn parseEvent(self: *QueueListener, msg: *c.dpiObject) !SentinelEvent {
        _ = self;
        // Extract fields from Oracle object type
        // [Implementation details for extracting sentinel_event_t fields]
        return .{
            .event_id = "",
            .event_type = .started,
            .process_id = "",
            .tenant_id = "",
            .timestamp_utc = 0,
            .payload = null,
        };
    }
    
    pub fn stop(self: *QueueListener) void {
        self.running.store(false, .seq_cst);
    }
    
    pub fn deinit(self: *QueueListener) void {
        _ = c.dpiDeqOptions_release(self.deq_options);
    }
};
```

### 4.4 Bulk Logger (Array DML)

```zig
// src/oracle/bulk_insert.zig
const std = @import("std");
const c = @import("../c_imports.zig").c;
const Allocator = std.mem.Allocator;

pub const LogEntry = struct {
    process_id: []const u8,
    tenant_id: []const u8,
    log_level: []const u8,
    message: []const u8,
    details_json: ?[]const u8,
    correlation_id: ?[]const u8,
};

pub const BulkLogger = struct {
    buffer: std.ArrayList(LogEntry),
    conn: *c.dpiConn,
    stmt: ?*c.dpiStmt,
    allocator: Allocator,
    
    const BATCH_SIZE: usize = 1000;
    const INSERT_SQL =
        \\INSERT INTO process_logs (
        \\    process_id, tenant_id, log_level, message, 
        \\    details, correlation_id, logged_at
        \\) VALUES (
        \\    :1, :2, :3, :4, :5, :6, SYSTIMESTAMP
        \\)
    ;
    
    pub fn init(allocator: Allocator, conn: *c.dpiConn) !BulkLogger {
        return .{
            .buffer = std.ArrayList(LogEntry).init(allocator),
            .conn = conn,
            .stmt = null,
            .allocator = allocator,
        };
    }
    
    pub fn log(self: *BulkLogger, entry: LogEntry) !void {
        try self.buffer.append(entry);
        
        if (self.buffer.items.len >= BATCH_SIZE) {
            try self.flush();
        }
    }
    
    pub fn flush(self: *BulkLogger) !void {
        if (self.buffer.items.len == 0) return;
        
        // Prepare statement if not already done
        if (self.stmt == null) {
            var stmt: *c.dpiStmt = undefined;
            if (c.dpiConn_prepareStmt(
                self.conn,
                0, // not scrollable
                INSERT_SQL.ptr, INSERT_SQL.len,
                null, 0, // tag
                &stmt,
            ) < 0) {
                return error.StatementPreparationFailed;
            }
            self.stmt = stmt;
        }
        
        const batch_count: u32 = @intCast(self.buffer.items.len);
        
        // Bind array variables for each column
        // [Detailed ODPI-C array binding implementation]
        
        // Execute with array DML
        var rows_affected: u64 = undefined;
        if (c.dpiStmt_executeMany(
            self.stmt.?,
            c.DPI_MODE_EXEC_DEFAULT,
            batch_count,
        ) < 0) {
            return error.BulkInsertFailed;
        }
        
        _ = c.dpiStmt_getRowCount(self.stmt.?, &rows_affected);
        std.log.info("Flushed {} log entries to Oracle", .{rows_affected});
        
        // Clear buffer
        self.buffer.clearRetainingCapacity();
    }
    
    pub fn deinit(self: *BulkLogger) void {
        if (self.stmt) |stmt| {
            _ = c.dpiStmt_release(stmt);
        }
        self.buffer.deinit();
    }
};
```

### 4.5 HTTP API Server

```zig
// src/api/server.zig
const std = @import("std");
const net = std.net;
const ConnectionPool = @import("../oracle/connection.zig").ConnectionPool;
const JwtValidator = @import("../security/jwt.zig").JwtValidator;

pub const ApiServer = struct {
    allocator: std.mem.Allocator,
    server: net.Server,
    pool: *ConnectionPool,
    jwt_validator: JwtValidator,
    
    const max_header_size = 8192;
    
    pub fn init(
        allocator: std.mem.Allocator,
        address: net.Address,
        pool: *ConnectionPool,
        jwt_config: JwtValidator.Config,
    ) !ApiServer {
        const server = try net.Address.listen(address, .{
            .reuse_address = true,
            .kernel_backlog = 128,
        });
        
        return .{
            .allocator = allocator,
            .server = server,
            .pool = pool,
            .jwt_validator = JwtValidator.init(jwt_config),
        };
    }
    
    pub fn run(self: *ApiServer) !void {
        std.log.info("Process Sentinel API listening on {}", .{self.server.listen_address});
        
        while (true) {
            const connection = self.server.accept() catch |err| {
                std.log.err("Accept error: {}", .{err});
                continue;
            };
            
            // Handle in thread pool (simplified - use actual thread pool)
            _ = std.Thread.spawn(.{}, handleConnection, .{ self, connection }) catch |err| {
                std.log.err("Thread spawn error: {}", .{err});
                connection.stream.close();
            };
        }
    }
    
    fn handleConnection(self: *ApiServer, connection: net.Server.Connection) void {
        defer connection.stream.close();
        
        // Per-request arena allocator
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        
        // Read and parse HTTP request
        var buf: [max_header_size]u8 = undefined;
        const request = self.parseRequest(&buf, connection.stream, alloc) catch |err| {
            std.log.err("Request parse error: {}", .{err});
            return;
        };
        
        // JWT validation
        const auth_header = request.headers.get("Authorization") orelse {
            self.sendUnauthorized(connection.stream);
            return;
        };
        
        const claims = self.jwt_validator.validate(auth_header) catch {
            self.sendUnauthorized(connection.stream);
            return;
        };
        
        // Route request
        self.routeRequest(request, claims, connection.stream, alloc) catch |err| {
            std.log.err("Request handling error: {}", .{err});
        };
    }
    
    fn routeRequest(
        self: *ApiServer,
        request: HttpRequest,
        claims: JwtValidator.Claims,
        stream: net.Stream,
        allocator: std.mem.Allocator,
    ) !void {
        const path = request.path;
        
        if (std.mem.startsWith(u8, path, "/status/")) {
            const process_id = path[8..];
            try self.handleGetStatus(process_id, claims.tenant_id, stream, allocator);
        } else if (std.mem.eql(u8, path, "/health")) {
            try self.handleHealth(stream);
        } else if (std.mem.eql(u8, path, "/metrics")) {
            try self.handleMetrics(stream, allocator);
        } else {
            try self.sendNotFound(stream);
        }
    }
    
    fn handleGetStatus(
        self: *ApiServer,
        process_id: []const u8,
        tenant_id: []const u8,
        stream: net.Stream,
        allocator: std.mem.Allocator,
    ) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);
        
        // Query process_live_status (fast GTT or persistent table)
        const sql =
            \\SELECT process_id, status, current_step, progress_percent,
            \\       TO_CHAR(last_update_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as last_update
            \\FROM process_live_status
            \\WHERE process_id = :1 AND tenant_id = :2
        ;
        
        // [Execute query and serialize to JSON]
        const json_response = try self.executeAndSerialize(conn, sql, .{process_id, tenant_id}, allocator);
        
        try self.sendJson(stream, json_response);
    }
    
    // [Additional handler implementations...]
};
```

---

## 5. Thread Pool Architecture

### 5.1 Worker Pool Design

```zig
// src/worker/pool.zig
const std = @import("std");
const ConnectionPool = @import("../oracle/connection.zig").ConnectionPool;

pub const WorkerPool = struct {
    workers: []Worker,
    task_queue: TaskQueue,
    oracle_pool: *ConnectionPool,
    shutdown: std.atomic.Value(bool),
    
    pub const Config = struct {
        num_workers: usize = 4,
        queue_capacity: usize = 10000,
    };
    
    pub fn init(allocator: std.mem.Allocator, oracle_pool: *ConnectionPool, config: Config) !WorkerPool {
        var workers = try allocator.alloc(Worker, config.num_workers);
        
        for (workers, 0..) |*worker, i| {
            worker.* = Worker{
                .id = i,
                .thread = undefined,
                .oracle_pool = oracle_pool,
            };
        }
        
        return .{
            .workers = workers,
            .task_queue = TaskQueue.init(allocator, config.queue_capacity),
            .oracle_pool = oracle_pool,
            .shutdown = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn start(self: *WorkerPool) !void {
        for (self.workers) |*worker| {
            worker.thread = try std.Thread.spawn(.{}, workerLoop, .{ worker, self });
        }
    }
    
    pub fn submit(self: *WorkerPool, task: Task) !void {
        try self.task_queue.push(task);
    }
    
    fn workerLoop(worker: *Worker, pool: *WorkerPool) void {
        // Each worker maintains its own Oracle connection for blocking calls
        const conn = pool.oracle_pool.acquire() catch {
            std.log.err("Worker {} failed to acquire connection", .{worker.id});
            return;
        };
        defer pool.oracle_pool.release(conn);
        
        while (!pool.shutdown.load(.seq_cst)) {
            const task = pool.task_queue.pop(100_000_000) catch continue; // 100ms timeout
            
            // Per-task arena
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            
            task.execute(conn, arena.allocator()) catch |err| {
                std.log.err("Task execution failed: {}", .{err});
            };
        }
    }
    
    pub fn shutdown(self: *WorkerPool) void {
        self.shutdown.store(true, .seq_cst);
        for (self.workers) |*worker| {
            worker.thread.join();
        }
    }
};

const Worker = struct {
    id: usize,
    thread: std.Thread,
    oracle_pool: *ConnectionPool,
};

pub const Task = struct {
    task_type: TaskType,
    payload: []const u8,
    callback: ?*const fn (anyerror!void) void,
    
    pub const TaskType = enum {
        log_batch,
        status_update,
        heartbeat_check,
        cleanup_expired,
    };
    
    pub fn execute(self: Task, conn: *anyopaque, allocator: std.mem.Allocator) !void {
        _ = allocator;
        _ = conn;
        switch (self.task_type) {
            .log_batch => {
                // Process batch log insertion
            },
            .status_update => {
                // Update process status
            },
            .heartbeat_check => {
                // Check for stale processes
            },
            .cleanup_expired => {
                // Archive old data
            },
        }
    }
};
```

---

## 6. Environment Configuration

### 6.1 Required Environment Variables

```bash
# Oracle Connection (shared with CLM Service)
ORACLE_WALLET_LOCATION=/path/to/wallet
ORACLE_TNS_NAME=clm_service_high
ORACLE_USERNAME=CLM_APP
ORACLE_PASSWORD=********

# Keycloak / OAuth2 (shared with CLM Service)
OAUTH2_JWK_SET_URI=https://keycloak.example.com/realms/clm/protocol/openid-connect/certs
OAUTH2_ISSUER_URI=https://keycloak.example.com/realms/clm
OAUTH2_AUDIENCE=clm-service

# Sentinel-specific
SENTINEL_HTTP_PORT=8090
SENTINEL_WORKER_THREADS=4
SENTINEL_QUEUE_NAME=SENTINEL_QUEUE
SENTINEL_LOG_BATCH_SIZE=1000
SENTINEL_HEARTBEAT_INTERVAL_SEC=30
SENTINEL_PROCESS_TIMEOUT_SEC=3600

# Telemetry
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
PROMETHEUS_METRICS_PORT=9090
```

### 6.2 Configuration Loading

```zig
// src/config/env.zig
const std = @import("std");

pub const Config = struct {
    // Oracle
    wallet_location: []const u8,
    tns_name: []const u8,
    username: []const u8,
    password: []const u8,
    
    // OAuth2
    jwk_set_uri: []const u8,
    issuer_uri: []const u8,
    audience: []const u8,
    
    // Sentinel
    http_port: u16,
    worker_threads: usize,
    queue_name: []const u8,
    log_batch_size: usize,
    heartbeat_interval_sec: u32,
    process_timeout_sec: u32,
    
    // Telemetry
    otel_endpoint: ?[]const u8,
    metrics_port: u16,
    
    pub fn load() !Config {
        return .{
            .wallet_location = std.posix.getenv("ORACLE_WALLET_LOCATION") orelse 
                return error.MissingWalletLocation,
            .tns_name = std.posix.getenv("ORACLE_TNS_NAME") orelse 
                return error.MissingTnsName,
            .username = std.posix.getenv("ORACLE_USERNAME") orelse 
                return error.MissingUsername,
            .password = std.posix.getenv("ORACLE_PASSWORD") orelse 
                return error.MissingPassword,
            
            .jwk_set_uri = std.posix.getenv("OAUTH2_JWK_SET_URI") orelse 
                return error.MissingJwkUri,
            .issuer_uri = std.posix.getenv("OAUTH2_ISSUER_URI") orelse 
                return error.MissingIssuerUri,
            .audience = std.posix.getenv("OAUTH2_AUDIENCE") orelse "clm-service",
            
            .http_port = try std.fmt.parseInt(u16, 
                std.posix.getenv("SENTINEL_HTTP_PORT") orelse "8090", 10),
            .worker_threads = try std.fmt.parseInt(usize, 
                std.posix.getenv("SENTINEL_WORKER_THREADS") orelse "4", 10),
            .queue_name = std.posix.getenv("SENTINEL_QUEUE_NAME") orelse "SENTINEL_QUEUE",
            .log_batch_size = try std.fmt.parseInt(usize, 
                std.posix.getenv("SENTINEL_LOG_BATCH_SIZE") orelse "1000", 10),
            .heartbeat_interval_sec = try std.fmt.parseInt(u32, 
                std.posix.getenv("SENTINEL_HEARTBEAT_INTERVAL_SEC") orelse "30", 10),
            .process_timeout_sec = try std.fmt.parseInt(u32, 
                std.posix.getenv("SENTINEL_PROCESS_TIMEOUT_SEC") orelse "3600", 10),
            
            .otel_endpoint = std.posix.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
            .metrics_port = try std.fmt.parseInt(u16, 
                std.posix.getenv("PROMETHEUS_METRICS_PORT") orelse "9090", 10),
        };
    }
};
```

---

## 7. Integration Points with CLM Service

### 7.1 Service-to-Sentinel Communication

```yaml
# Add to CLM Service application.yml

sentinel:
  enabled: ${SENTINEL_ENABLED:true}
  base-url: ${SENTINEL_BASE_URL:http://localhost:8090}
  connect-timeout: 5000
  read-timeout: 10000
  # Service account for internal calls
  client-id: ${SENTINEL_CLIENT_ID:clm-service}
  client-secret: ${SENTINEL_CLIENT_SECRET:}
```

### 7.2 Camel Integration Route

```java
// Add to CLM Service: src/main/java/com/gprintex/clm/camel/SentinelIntegrationRoute.java

@Component
public class SentinelIntegrationRoute extends RouteBuilder {
    
    @Override
    public void configure() throws Exception {
        // Intercept long-running processes and notify Sentinel
        from("direct:sentinel-start")
            .routeId("sentinel-process-start")
            .setHeader("X-Sentinel-Process-Id", simple("${exchangeId}"))
            .to("http://{{sentinel.base-url}}/internal/start?httpMethod=POST");
        
        from("direct:sentinel-complete")
            .routeId("sentinel-process-complete")
            .to("http://{{sentinel.base-url}}/internal/complete?httpMethod=POST");
        
        from("direct:sentinel-error")
            .routeId("sentinel-process-error")
            .to("http://{{sentinel.base-url}}/internal/error?httpMethod=POST");
    }
}
```

### 7.3 PL/SQL Integration Example

```sql
-- Example usage in existing CLM packages

CREATE OR REPLACE PROCEDURE contract_pkg.create_contract(
    p_tenant_id   IN VARCHAR2,
    p_contract    IN contract_t,
    p_result      OUT SYS_REFCURSOR
) IS
    l_process_id VARCHAR2(100);
BEGIN
    -- Start sentinel monitoring
    l_process_id := sentinel_pkg.start_proc('CONTRACT_PKG', 'CREATE_CONTRACT', p_tenant_id);
    
    BEGIN
        sentinel_pkg.update_progress(l_process_id, 'VALIDATING_INPUT', 10);
        
        -- Validation logic...
        
        sentinel_pkg.update_progress(l_process_id, 'INSERTING_CONTRACT', 40);
        
        -- Insert logic...
        
        sentinel_pkg.update_progress(l_process_id, 'CREATING_ITEMS', 70);
        
        -- Items logic...
        
        sentinel_pkg.update_progress(l_process_id, 'FINALIZING', 95);
        
        -- Final steps...
        
        sentinel_pkg.complete_process(l_process_id, '{"contract_id": "..."}');
        
    EXCEPTION
        WHEN OTHERS THEN
            sentinel_pkg.fail_process(
                p_process_id    => l_process_id,
                p_error_code    => SQLCODE,
                p_error_message => SQLERRM,
                p_stack_trace   => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            RAISE;
    END;
END create_contract;
```

---

## 8. API Reference

### 8.1 REST Endpoints

| Method | Path                    | Description                    | Auth         |
|--------|-------------------------|--------------------------------|--------------|
| GET    | `/status/{processId}`   | Get live process status        | JWT Bearer   |
| GET    | `/processes`            | List active processes (tenant) | JWT Bearer   |
| GET    | `/logs/{processId}`     | Stream process logs            | JWT Bearer   |
| GET    | `/health`               | Liveness probe                 | None         |
| GET    | `/ready`                | Readiness probe                | None         |
| GET    | `/metrics`              | Prometheus metrics             | mTLS Cert    |

### 8.2 Response Examples

```json
// GET /status/ABC123DEF456
{
  "process_id": "ABC123DEF456",
  "status": "RUNNING",
  "current_step": "INSERTING_CONTRACT",
  "progress_percent": 40.0,
  "started_at": "2026-01-28T10:30:00Z",
  "last_update_at": "2026-01-28T10:30:15Z",
  "estimated_completion": "2026-01-28T10:31:00Z",
  "metadata": {
    "package": "CONTRACT_PKG",
    "procedure": "CREATE_CONTRACT",
    "tenant_id": "tenant-001"
  }
}
```

---

## 9. Deployment

### 9.1 Container Image

```dockerfile
# Dockerfile
FROM debian:bookworm-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    libc-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Zig
ARG ZIG_VERSION=0.13.0
RUN curl -L https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz \
    | tar -xJ -C /opt
ENV PATH="/opt/zig-linux-x86_64-${ZIG_VERSION}:$PATH"

# Install Oracle Instant Client
COPY oracle-instantclient*.rpm /tmp/
RUN apt-get update && apt-get install -y alien \
    && alien -i /tmp/oracle-instantclient*.rpm \
    && rm /tmp/*.rpm

WORKDIR /app
COPY . .

# Build release binary
RUN zig build -Doptimize=ReleaseFast

# Runtime image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libaio1 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/lib/oracle /usr/lib/oracle
COPY --from=builder /app/zig-out/bin/process-sentinel /usr/local/bin/

ENV LD_LIBRARY_PATH=/usr/lib/oracle/21/client64/lib
ENV ORACLE_HOME=/usr/lib/oracle/21/client64

EXPOSE 8090 9090

USER nobody
ENTRYPOINT ["/usr/local/bin/process-sentinel"]
```

### 9.2 Kubernetes Deployment

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: process-sentinel
  namespace: clm
spec:
  replicas: 2
  selector:
    matchLabels:
      app: process-sentinel
  template:
    metadata:
      labels:
        app: process-sentinel
    spec:
      serviceAccountName: clm-service-account
      containers:
        - name: sentinel
          image: gprintex/process-sentinel:latest
          ports:
            - containerPort: 8090
              name: http
            - containerPort: 9090
              name: metrics
          envFrom:
            - secretRef:
                name: oracle-credentials
            - configMapRef:
                name: sentinel-config
          volumeMounts:
            - name: oracle-wallet
              mountPath: /etc/oracle/wallet
              readOnly: true
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          livenessProbe:
            httpGet:
              path: /health
              port: 8090
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /ready
              port: 8090
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: oracle-wallet
          secret:
            secretName: oracle-wallet-secret
```

---

## 10. Performance Targets

| Metric                      | Target           | Measurement Method        |
|-----------------------------|------------------|---------------------------|
| AQ Dequeue Latency          | < 5ms            | p99 from OTEL traces      |
| Status Query Response       | < 10ms           | HTTP response time        |
| Log Batch Insert            | 1000 rows/10ms   | Oracle AWR                |
| Memory per Request          | < 4KB average    | Arena allocator stats     |
| Connection Pool Efficiency  | > 95% reuse      | Pool metrics              |
| Event Processing Throughput | > 10,000/sec     | Load test benchmark       |

---

## 11. Security Checklist

- [ ] Oracle Wallet configured with auto-login SSO (no password in env)
- [ ] mTLS enabled between Sentinel and CLM Service
- [ ] JWT validation using shared Keycloak realm
- [ ] Tenant isolation enforced at query level
- [ ] No plaintext secrets in logs
- [ ] TLS 1.3 for all network connections
- [ ] Container runs as non-root user
- [ ] Network policies restrict pod-to-pod communication
- [ ] Secrets mounted as volumes, not env vars
- [ ] OWASP dependency scanning in CI/CD

---

## Appendix A: Quick Start

```bash
# 1. Clone and enter project
git clone git@github.com:zlovtnik/process-sentinel.git
cd process-sentinel

# 2. Install Oracle Instant Client (macOS example)
brew tap InstantClientTap/instantclient
brew install instantclient-basic instantclient-sdk

# 3. Clone ODPI-C
git clone https://github.com/oracle/odpi.git deps/odpi

# 4. Set environment
export ORACLE_HOME=$(brew --prefix)/lib
export ODPIC_PATH=deps/odpi
source ../clm-service/.env  # Reuse CLM credentials

# 5. Build
zig build

# 6. Run
./zig-out/bin/process-sentinel
```

---

*Document Version: 1.0.0*  
*Last Updated: 2026-01-28*  
*Author: GprintEx Engineering*
