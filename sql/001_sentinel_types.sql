-- =============================================================================
-- 001_sentinel_types.sql
-- Oracle Types for Process Sentinel
-- =============================================================================

-- Drop existing types if they exist (for clean re-run)
-- Order: dependent types first (sentinel_log_array_t depends on sentinel_log_entry_t)
BEGIN
    EXECUTE IMMEDIATE 'DROP TYPE sentinel_log_array_t FORCE';
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'DROP TYPE sentinel_log_entry_t FORCE';
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'DROP TYPE sentinel_event_t FORCE';
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

-- =============================================================================
-- SENTINEL_EVENT_T: AQ Message payload type
-- =============================================================================
CREATE OR REPLACE TYPE sentinel_event_t AS OBJECT (
    event_id        VARCHAR2(100),     -- Unique event identifier (GUID)
    event_type      VARCHAR2(50),      -- STARTED, HEARTBEAT, PROGRESS, COMPLETED, ERROR
    process_id      VARCHAR2(100),     -- Process being monitored
    tenant_id       VARCHAR2(50),      -- Multi-tenant identifier
    timestamp_utc   TIMESTAMP,         -- Event timestamp (UTC)
    payload         CLOB               -- JSON payload with additional data
);
/

COMMENT ON TYPE sentinel_event_t IS 'Oracle AQ message payload for real-time process events';

-- =============================================================================
-- SENTINEL_LOG_ENTRY_T: Single log entry type
-- =============================================================================
CREATE OR REPLACE TYPE sentinel_log_entry_t AS OBJECT (
    process_id      VARCHAR2(100),
    tenant_id       VARCHAR2(50),
    log_level       VARCHAR2(10),
    event_type      VARCHAR2(50),
    component       VARCHAR2(100),
    message         VARCHAR2(4000),
    details         CLOB,
    stack_trace     CLOB,
    correlation_id  VARCHAR2(100),
    span_id         VARCHAR2(32),
    trace_id        VARCHAR2(32),
    event_duration_us NUMBER,
    logged_at       TIMESTAMP(6)
);
/

COMMENT ON TYPE sentinel_log_entry_t IS 'Single log entry for bulk insertion';

-- =============================================================================
-- SENTINEL_LOG_ARRAY_T: Array of log entries for bulk operations
-- =============================================================================
CREATE OR REPLACE TYPE sentinel_log_array_t AS TABLE OF sentinel_log_entry_t;
/

COMMENT ON TYPE sentinel_log_array_t IS 'Array type for bulk log insertion';

-- =============================================================================
-- Grant permissions
-- =============================================================================
-- Replace CLM_APP with your application schema
GRANT EXECUTE ON sentinel_event_t TO clm_app;
GRANT EXECUTE ON sentinel_log_entry_t TO clm_app;
GRANT EXECUTE ON sentinel_log_array_t TO clm_app;

-- Verify types created
SELECT object_name, object_type, status 
FROM user_objects 
WHERE object_name LIKE 'SENTINEL%' 
  AND object_type = 'TYPE'
ORDER BY object_name;
