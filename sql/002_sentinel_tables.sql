-- =============================================================================
-- 002_sentinel_tables.sql
-- Database Tables for Process Sentinel
-- =============================================================================

-- =============================================================================
-- PROCESS_REGISTRY: Master process catalog
-- =============================================================================
CREATE TABLE process_registry (
    process_id          VARCHAR2(100) PRIMARY KEY,
    process_uuid        RAW(16) DEFAULT SYS_GUID() NOT NULL,
    
    -- Classification
    process_type        VARCHAR2(50) NOT NULL,
    process_name        VARCHAR2(200) NOT NULL,
    package_name        VARCHAR2(128),      -- e.g., 'CONTRACT_PKG'
    procedure_name      VARCHAR2(128),      -- e.g., 'CREATE_CONTRACT'
    
    -- Ownership
    tenant_id           VARCHAR2(50) NOT NULL,
    owner_service       VARCHAR2(100) DEFAULT 'CLM_SERVICE',
    
    -- Lifecycle
    status              VARCHAR2(20) DEFAULT 'REGISTERED' NOT NULL,
    registered_at       TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    last_heartbeat_at   TIMESTAMP,
    expires_at          TIMESTAMP,
    
    -- Configuration (Oracle 21c+ native JSON)
    config              CLOB CHECK (config IS JSON),
    tags                CLOB CHECK (tags IS JSON),
    
    -- Metrics
    total_executions    NUMBER DEFAULT 0,
    successful_runs     NUMBER DEFAULT 0,
    failed_runs         NUMBER DEFAULT 0,
    avg_duration_ms     NUMBER,
    
    -- Constraints
    CONSTRAINT uq_process_uuid UNIQUE (process_uuid),
    CONSTRAINT chk_process_status CHECK (status IN (
        'REGISTERED', 'ACTIVE', 'RUNNING', 'PAUSED', 
        'COMPLETED', 'FAILED', 'EXPIRED', 'ARCHIVED'
    ))
)
-- Partition by tenant for multi-tenant isolation
PARTITION BY LIST (tenant_id) AUTOMATIC (
    PARTITION p_default VALUES ('DEFAULT')
)
TABLESPACE clm_data;

-- Indexes
CREATE INDEX idx_process_tenant_status ON process_registry(tenant_id, status) LOCAL;
CREATE INDEX idx_process_package ON process_registry(package_name, procedure_name);
CREATE INDEX idx_process_heartbeat ON process_registry(last_heartbeat_at) LOCAL;
CREATE INDEX idx_process_registered ON process_registry(registered_at DESC) LOCAL;

COMMENT ON TABLE process_registry IS 'Master catalog of all monitored processes';
COMMENT ON COLUMN process_registry.process_id IS 'Primary identifier (hex GUID)';
COMMENT ON COLUMN process_registry.tenant_id IS 'Multi-tenant isolation key';
COMMENT ON COLUMN process_registry.package_name IS 'PL/SQL package containing the procedure';

-- =============================================================================
-- PROCESS_LIVE_STATUS_GTT: In-session real-time status (Global Temporary Table)
-- =============================================================================
CREATE GLOBAL TEMPORARY TABLE process_live_status_gtt (
    process_id          VARCHAR2(100) PRIMARY KEY,
    status              VARCHAR2(20) NOT NULL,
    started_at          TIMESTAMP,
    current_step        VARCHAR2(200),
    progress_percent    NUMBER(5,2),
    last_update_at      TIMESTAMP DEFAULT SYSTIMESTAMP,
    metadata            CLOB CHECK (metadata IS JSON)
) ON COMMIT PRESERVE ROWS;

COMMENT ON TABLE process_live_status_gtt IS 'Per-session live status for fast updates';

-- =============================================================================
-- PROCESS_LIVE_STATUS: Persistent mirror for cross-session queries
-- =============================================================================
CREATE TABLE process_live_status (
    process_id          VARCHAR2(100) PRIMARY KEY,
    tenant_id           VARCHAR2(50) NOT NULL,
    status              VARCHAR2(20) NOT NULL,
    started_at          TIMESTAMP,
    current_step        VARCHAR2(200),
    progress_percent    NUMBER(5,2),
    last_update_at      TIMESTAMP DEFAULT SYSTIMESTAMP,
    estimated_completion TIMESTAMP,
    metadata            CLOB CHECK (metadata IS JSON),
    
    -- Foreign key to parent registry
    CONSTRAINT fk_live_process FOREIGN KEY (process_id)
        REFERENCES process_registry(process_id) ON DELETE CASCADE,
    
    -- CANONICAL STATUS LIST: Keep in sync with process_registry.chk_status
    -- If modifying valid statuses, update BOTH constraints together.
    -- See process_registry.chk_status for the authoritative list.
    CONSTRAINT chk_live_status CHECK (status IN (
        'REGISTERED', 'ACTIVE', 'RUNNING', 'PAUSED', 
        'COMPLETED', 'FAILED', 'EXPIRED', 'ARCHIVED'
    ))
)
TABLESPACE clm_data;

CREATE INDEX idx_live_status_tenant ON process_live_status(tenant_id, status);
CREATE INDEX idx_live_status_update ON process_live_status(last_update_at DESC);

COMMENT ON TABLE process_live_status IS 'Persistent real-time status queryable across sessions';

-- =============================================================================
-- PROCESS_LOGS: High-volume logging with interval partitioning
-- =============================================================================
CREATE TABLE process_logs (
    log_id              NUMBER GENERATED ALWAYS AS IDENTITY NOT NULL,
    log_uuid            RAW(16) DEFAULT SYS_GUID() NOT NULL,
    
    -- Primary key includes partition key for LOCAL index
    -- Note: Cross-partition uniqueness of log_id is guaranteed by IDENTITY
    CONSTRAINT pk_process_logs PRIMARY KEY (log_id, logged_at),
    -- Unique constraint includes partition key for LOCAL index
    -- Note: If cross-partition uniqueness is required, convert to GLOBAL and
    -- update partition maintenance scripts to use UPDATE GLOBAL INDEXES
    CONSTRAINT uq_log_uuid UNIQUE (log_uuid, logged_at),
    
    -- Foreign keys
    process_id          VARCHAR2(100) NOT NULL,
    tenant_id           VARCHAR2(50) NOT NULL,
    
    -- Event classification
    log_level           VARCHAR2(10) NOT NULL,
    event_type          VARCHAR2(50),
    component           VARCHAR2(100),
    
    -- Content
    message             VARCHAR2(4000),
    details             CLOB CHECK (details IS JSON),
    stack_trace         CLOB,
    
    -- Timing
    logged_at           TIMESTAMP(6) DEFAULT SYSTIMESTAMP NOT NULL,
    event_duration_us   NUMBER,     -- Microseconds
    
    -- Correlation / Tracing
    correlation_id      VARCHAR2(100),
    span_id             VARCHAR2(32),
    trace_id            VARCHAR2(32),
    
    -- Constraints
    CONSTRAINT chk_log_level CHECK (log_level IN (
        'TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'
    ))
)
-- Interval partition by day for automatic partition management
PARTITION BY RANGE (logged_at) INTERVAL (NUMTODSINTERVAL(1, 'DAY')) (
    PARTITION p_initial VALUES LESS THAN (TIMESTAMP '2026-01-01 00:00:00')
)
TABLESPACE clm_data
LOB (details, stack_trace) STORE AS SECUREFILE (
    TABLESPACE clm_data
    COMPRESS HIGH
    DEDUPLICATE
    CACHE READS
);

-- Indexes (local to partitions)
CREATE INDEX idx_logs_process_time ON process_logs(process_id, logged_at DESC) LOCAL;
CREATE INDEX idx_logs_tenant_level ON process_logs(tenant_id, log_level, logged_at DESC) LOCAL;
CREATE INDEX idx_logs_correlation ON process_logs(correlation_id) LOCAL;
CREATE INDEX idx_logs_trace ON process_logs(trace_id) LOCAL;

COMMENT ON TABLE process_logs IS 'High-volume process event logging with daily partitions';
COMMENT ON COLUMN process_logs.details IS 'JSON details (OSON binary on Oracle 21c+)';
COMMENT ON COLUMN process_logs.event_duration_us IS 'Event duration in microseconds';

-- =============================================================================
-- PROCESS_METRICS: Aggregated metrics per process
-- =============================================================================
CREATE TABLE process_metrics (
    metric_id           NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    process_id          VARCHAR2(100) NOT NULL,
    tenant_id           VARCHAR2(50) NOT NULL,
    
    -- Time bucket
    bucket_start        TIMESTAMP NOT NULL,
    bucket_end          TIMESTAMP NOT NULL,
    granularity         VARCHAR2(20) NOT NULL, -- MINUTE, HOUR, DAY
    
    -- Counters
    execution_count     NUMBER DEFAULT 0,
    success_count       NUMBER DEFAULT 0,
    failure_count       NUMBER DEFAULT 0,
    
    -- Timing (milliseconds)
    total_duration_ms   NUMBER DEFAULT 0,
    min_duration_ms     NUMBER,
    max_duration_ms     NUMBER,
    avg_duration_ms     NUMBER,
    p50_duration_ms     NUMBER,
    p95_duration_ms     NUMBER,
    p99_duration_ms     NUMBER,
    
    -- Logging
    log_count_error     NUMBER DEFAULT 0,
    log_count_warn      NUMBER DEFAULT 0,
    log_count_info      NUMBER DEFAULT 0,
    
    created_at          TIMESTAMP DEFAULT SYSTIMESTAMP,
    
    CONSTRAINT uq_process_metric_bucket UNIQUE (process_id, bucket_start, granularity)
)
TABLESPACE clm_data;

CREATE INDEX idx_metrics_tenant_time ON process_metrics(tenant_id, bucket_start DESC);

COMMENT ON TABLE process_metrics IS 'Pre-aggregated metrics for dashboards';

-- =============================================================================
-- Grant permissions
-- =============================================================================
GRANT SELECT, INSERT, UPDATE, DELETE ON process_registry TO clm_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON process_live_status TO clm_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON process_live_status_gtt TO clm_app;
GRANT SELECT, INSERT ON process_logs TO clm_app;
GRANT SELECT, INSERT, UPDATE ON process_metrics TO clm_app;

-- Verify tables created
SELECT table_name, partitioned, num_rows
FROM user_tables
WHERE table_name LIKE 'PROCESS%'
ORDER BY table_name;
