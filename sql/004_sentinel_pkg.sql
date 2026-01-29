-- =============================================================================
-- 004_sentinel_pkg.sql
-- Sentinel PL/SQL Package - Developer SDK for Process Monitoring
-- =============================================================================

CREATE OR REPLACE PACKAGE sentinel_pkg AS
    -- =========================================================================
    -- CONSTANTS
    -- =========================================================================
    
    -- Event types
    c_event_started     CONSTANT VARCHAR2(20) := 'STARTED';
    c_event_heartbeat   CONSTANT VARCHAR2(20) := 'HEARTBEAT';
    c_event_progress    CONSTANT VARCHAR2(20) := 'PROGRESS';
    c_event_completed   CONSTANT VARCHAR2(20) := 'COMPLETED';
    c_event_error       CONSTANT VARCHAR2(20) := 'ERROR';
    
    -- Log levels
    c_log_trace         CONSTANT VARCHAR2(10) := 'TRACE';
    c_log_debug         CONSTANT VARCHAR2(10) := 'DEBUG';
    c_log_info          CONSTANT VARCHAR2(10) := 'INFO';
    c_log_warn          CONSTANT VARCHAR2(10) := 'WARN';
    c_log_error         CONSTANT VARCHAR2(10) := 'ERROR';
    c_log_fatal         CONSTANT VARCHAR2(10) := 'FATAL';
    
    -- Process statuses
    c_status_registered CONSTANT VARCHAR2(20) := 'REGISTERED';
    c_status_running    CONSTANT VARCHAR2(20) := 'RUNNING';
    c_status_completed  CONSTANT VARCHAR2(20) := 'COMPLETED';
    c_status_failed     CONSTANT VARCHAR2(20) := 'FAILED';
    
    -- =========================================================================
    -- PROCESS LIFECYCLE
    -- =========================================================================
    
    -- Start monitoring a process (procedure version with OUT param)
    PROCEDURE start_process(
        p_package_name    IN VARCHAR2,
        p_procedure_name  IN VARCHAR2 DEFAULT NULL,
        p_tenant_id       IN VARCHAR2 DEFAULT SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
        p_correlation_id  IN VARCHAR2 DEFAULT NULL,
        p_metadata        IN CLOB DEFAULT NULL,
        p_process_id      OUT VARCHAR2
    );
    
    -- Start monitoring a process (function version - returns process_id)
    FUNCTION start_proc(
        p_package_name    IN VARCHAR2,
        p_procedure_name  IN VARCHAR2 DEFAULT NULL,
        p_tenant_id       IN VARCHAR2 DEFAULT SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
        p_correlation_id  IN VARCHAR2 DEFAULT NULL,
        p_metadata        IN CLOB DEFAULT NULL
    ) RETURN VARCHAR2;
    
    -- Update progress during execution
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
    
    -- Mark process as completed successfully
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
    
    -- =========================================================================
    -- LOGGING
    -- =========================================================================
    
    PROCEDURE log_trace(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL
    );
    
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
    
    PROCEDURE log_fatal(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL,
        p_stack_trace IN CLOB DEFAULT NULL
    );
    
    -- Generic log procedure
    PROCEDURE log_event(
        p_process_id   IN VARCHAR2,
        p_log_level    IN VARCHAR2,
        p_message      IN VARCHAR2,
        p_event_type   IN VARCHAR2 DEFAULT NULL,
        p_component    IN VARCHAR2 DEFAULT NULL,
        p_details      IN CLOB DEFAULT NULL,
        p_stack_trace  IN CLOB DEFAULT NULL,
        p_correlation_id IN VARCHAR2 DEFAULT NULL
    );
    
    -- =========================================================================
    -- INTERNAL: Queue Operations
    -- =========================================================================
    
    PROCEDURE notify_sentinel(
        p_event_type   IN VARCHAR2,
        p_process_id   IN VARCHAR2,
        p_tenant_id    IN VARCHAR2,
        p_payload      IN CLOB DEFAULT NULL
    );
    
    -- =========================================================================
    -- UTILITY
    -- =========================================================================
    
    -- Get current process status
    FUNCTION get_status(
        p_process_id IN VARCHAR2
    ) RETURN VARCHAR2;
    
    -- Check if process is still running
    FUNCTION is_running(
        p_process_id IN VARCHAR2
    ) RETURN BOOLEAN;
    
END sentinel_pkg;
/

-- =============================================================================
-- PACKAGE BODY
-- =============================================================================

CREATE OR REPLACE PACKAGE BODY sentinel_pkg AS

    -- Private: Escape a string for safe JSON embedding
    -- Handles backslash, double-quote, and control characters (CR, LF, TAB, FF, BS)
    -- Truncates input to prevent VARCHAR2 overflow
    FUNCTION escape_json_string(
        p_value IN VARCHAR2,
        p_max_len IN NUMBER DEFAULT 2000
    ) RETURN VARCHAR2 IS
        l_truncated VARCHAR2(4000);
    BEGIN
        -- Truncate to prevent overflow (escaping can double size)
        l_truncated := SUBSTR(NVL(p_value, ''), 1, p_max_len);
        
        -- Chain REPLACE for all JSON special characters
        RETURN REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            l_truncated,
            '\', '\\'),      -- backslash must be first
            '"', '\"'),      -- double-quote
            CHR(10), '\n'),  -- newline
            CHR(13), '\r'),  -- carriage return
            CHR(9), '\t'),   -- tab
            CHR(12), '\f'),  -- form feed
            CHR(8), '\b');   -- backspace
    END escape_json_string;

    -- Private: Get tenant ID with fallback
    FUNCTION get_tenant_id(p_tenant_id IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN NVL(
            p_tenant_id,
            NVL(
                SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
                'DEFAULT'
            )
        );
    END get_tenant_id;
    
    -- Private: Insert log entry
    PROCEDURE insert_log(
        p_process_id    IN VARCHAR2,
        p_tenant_id     IN VARCHAR2,
        p_log_level     IN VARCHAR2,
        p_message       IN VARCHAR2,
        p_event_type    IN VARCHAR2 DEFAULT NULL,
        p_component     IN VARCHAR2 DEFAULT NULL,
        p_details       IN CLOB DEFAULT NULL,
        p_stack_trace   IN CLOB DEFAULT NULL,
        p_correlation_id IN VARCHAR2 DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO process_logs (
            process_id, tenant_id, log_level, message,
            event_type, component, details, stack_trace,
            correlation_id, logged_at
        ) VALUES (
            p_process_id, get_tenant_id(p_tenant_id), p_log_level, p_message,
            p_event_type, p_component, p_details, p_stack_trace,
            p_correlation_id, SYSTIMESTAMP
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            -- Don't propagate logging errors
            NULL;
    END insert_log;

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
        l_uuid      RAW(16);
        l_tenant_id VARCHAR2(50);
    BEGIN
        -- Validate required parameter
        IF TRIM(p_package_name) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20002, 
                'start_process: p_package_name is required and cannot be NULL or empty');
        END IF;
        
        l_uuid := SYS_GUID();
        p_process_id := RAWTOHEX(l_uuid);
        l_tenant_id := get_tenant_id(p_tenant_id);
        
        -- Register in process_registry
        INSERT INTO process_registry (
            process_id, process_uuid, process_type, process_name,
            package_name, procedure_name, tenant_id, status,
            registered_at
        ) VALUES (
            p_process_id, l_uuid, 'PLSQL_PROCEDURE', 
            p_package_name || '.' || NVL(p_procedure_name, '*'),
            p_package_name, p_procedure_name, 
            l_tenant_id, c_status_running,
            SYSTIMESTAMP
        );
        
        -- Initialize live status
        INSERT INTO process_live_status (
            process_id, tenant_id, status, started_at, 
            current_step, progress_percent, last_update_at
        ) VALUES (
            p_process_id, l_tenant_id, c_status_running, 
            SYSTIMESTAMP, 'INITIALIZING', 0, SYSTIMESTAMP
        );
        
        -- Notify sentinel (async)
        notify_sentinel(c_event_started, p_process_id, l_tenant_id, p_metadata);
        
        -- Log start
        insert_log(p_process_id, l_tenant_id, c_log_info, 
            'Process started: ' || p_package_name || '.' || NVL(p_procedure_name, '*'),
            c_event_started, p_package_name, p_metadata, NULL, p_correlation_id);
        
        COMMIT;
    END start_process;
    
    -- -------------------------------------------------------------------------
    -- start_proc: Convenience function
    -- -------------------------------------------------------------------------
    FUNCTION start_proc(
        p_package_name    IN VARCHAR2,
        p_procedure_name  IN VARCHAR2 DEFAULT NULL,
        p_tenant_id       IN VARCHAR2 DEFAULT SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
        p_correlation_id  IN VARCHAR2 DEFAULT NULL,
        p_metadata        IN CLOB DEFAULT NULL
    ) RETURN VARCHAR2 IS
        l_process_id VARCHAR2(100);
    BEGIN
        start_process(
            p_package_name   => p_package_name,
            p_procedure_name => p_procedure_name,
            p_tenant_id      => p_tenant_id,
            p_correlation_id => p_correlation_id,
            p_metadata       => p_metadata,
            p_process_id     => l_process_id
        );
        RETURN l_process_id;
    END start_proc;
    
    -- -------------------------------------------------------------------------
    -- update_progress: Update current step and percentage
    -- -------------------------------------------------------------------------
    PROCEDURE update_progress(
        p_process_id      IN VARCHAR2,
        p_current_step    IN VARCHAR2,
        p_progress_pct    IN NUMBER DEFAULT NULL,
        p_metadata        IN CLOB DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_escaped_step VARCHAR2(4000);
    BEGIN
        UPDATE process_live_status
        SET current_step = p_current_step,
            progress_percent = NVL(p_progress_pct, progress_percent),
            metadata = NVL(p_metadata, metadata),
            last_update_at = SYSTIMESTAMP
        WHERE process_id = p_process_id;
        
        -- Use helper function for consistent escaping
        l_escaped_step := escape_json_string(p_current_step, 2000);
        
        -- Notify sentinel with escaped step
        notify_sentinel(c_event_progress, p_process_id, NULL,
            '{"step":"' || l_escaped_step || '","progress":' || NVL(p_progress_pct, 0) || '}');
        
        COMMIT;
    END update_progress;
    
    -- -------------------------------------------------------------------------
    -- heartbeat: Keep process alive
    -- -------------------------------------------------------------------------
    PROCEDURE heartbeat(
        p_process_id      IN VARCHAR2,
        p_status_message  IN VARCHAR2 DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_escaped_msg VARCHAR2(4000);
    BEGIN
        UPDATE process_registry
        SET last_heartbeat_at = SYSTIMESTAMP
        WHERE process_id = p_process_id;
        
        UPDATE process_live_status
        SET last_update_at = SYSTIMESTAMP
        WHERE process_id = p_process_id;
        
        -- Use helper function for consistent escaping
        l_escaped_msg := escape_json_string(NVL(p_status_message, 'alive'));
        
        notify_sentinel(c_event_heartbeat, p_process_id, NULL,
            '{"message":"' || l_escaped_msg || '"}');
        
        COMMIT;
    END heartbeat;
    
    -- -------------------------------------------------------------------------
    -- complete_process: Mark as successfully completed
    -- -------------------------------------------------------------------------
    PROCEDURE complete_process(
        p_process_id      IN VARCHAR2,
        p_result          IN CLOB DEFAULT NULL
    ) IS
        l_tenant_id VARCHAR2(50);
        l_started_at TIMESTAMP;
        l_duration_ms NUMBER;
    BEGIN
        -- Get timing info with proper error handling
        BEGIN
            SELECT tenant_id, started_at
            INTO l_tenant_id, l_started_at
            FROM process_live_status
            WHERE process_id = p_process_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20003, 
                    'complete_process: Process not found: ' || p_process_id);
        END;
        
        -- Calculate full duration in milliseconds (handles hours/days)
        -- Compute interval once to avoid racey duration from multiple SYSTIMESTAMP evaluations
        DECLARE
            l_elapsed_interval INTERVAL DAY TO SECOND := SYSTIMESTAMP - l_started_at;
        BEGIN
            l_duration_ms := (
                EXTRACT(DAY FROM l_elapsed_interval) * 86400000 +
                EXTRACT(HOUR FROM l_elapsed_interval) * 3600000 +
                EXTRACT(MINUTE FROM l_elapsed_interval) * 60000 +
                EXTRACT(SECOND FROM l_elapsed_interval) * 1000
            );
        END;
        
        -- Update registry
        UPDATE process_registry
        SET status = c_status_completed,
            total_executions = total_executions + 1,
            successful_runs = successful_runs + 1,
            avg_duration_ms = NVL(
                (avg_duration_ms * (total_executions - 1) + l_duration_ms) / total_executions,
                l_duration_ms
            )
        WHERE process_id = p_process_id;
        
        -- Update live status
        UPDATE process_live_status
        SET status = c_status_completed,
            current_step = 'COMPLETED',
            progress_percent = 100,
            last_update_at = SYSTIMESTAMP
        WHERE process_id = p_process_id;
        
        -- Notify sentinel
        notify_sentinel(c_event_completed, p_process_id, l_tenant_id, p_result);
        
        -- Log completion
        insert_log(p_process_id, l_tenant_id, c_log_info,
            'Process completed successfully in ' || ROUND(l_duration_ms) || 'ms',
            c_event_completed);
        
        COMMIT;
    END complete_process;
    
    -- -------------------------------------------------------------------------
    -- fail_process: Mark as failed
    -- -------------------------------------------------------------------------
    PROCEDURE fail_process(
        p_process_id      IN VARCHAR2,
        p_error_code      IN VARCHAR2,
        p_error_message   IN VARCHAR2,
        p_stack_trace     IN CLOB DEFAULT NULL
    ) IS
        l_tenant_id VARCHAR2(50);
        l_payload CLOB;
        l_escaped_code VARCHAR2(4000);
        l_escaped_msg VARCHAR2(4000);
    BEGIN
        -- Get tenant with proper error handling
        BEGIN
            SELECT tenant_id INTO l_tenant_id
            FROM process_live_status
            WHERE process_id = p_process_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20004, 
                    'fail_process: Process not found: ' || p_process_id);
        END;
        
        -- Update registry
        UPDATE process_registry
        SET status = c_status_failed,
            total_executions = total_executions + 1,
            failed_runs = failed_runs + 1
        WHERE process_id = p_process_id;
        
        -- Update live status
        UPDATE process_live_status
        SET status = c_status_failed,
            current_step = 'FAILED: ' || p_error_code,
            last_update_at = SYSTIMESTAMP
        WHERE process_id = p_process_id;
        
        -- Use helper function for consistent escaping
        l_escaped_code := escape_json_string(NVL(p_error_code, 'UNKNOWN'));
        l_escaped_msg := escape_json_string(NVL(p_error_message, 'No message provided'));
        
        -- Build properly escaped payload
        l_payload := '{"error_code":"' || l_escaped_code || 
                     '","error_message":"' || l_escaped_msg || '"}';
        
        -- Notify sentinel
        notify_sentinel(c_event_error, p_process_id, l_tenant_id, l_payload);
        
        -- Log error
        insert_log(p_process_id, l_tenant_id, c_log_error,
            p_error_code || ': ' || p_error_message,
            c_event_error, NULL, l_payload, p_stack_trace);
        
        COMMIT;
    END fail_process;
    
    -- -------------------------------------------------------------------------
    -- notify_sentinel: Enqueue event to AQ
    -- -------------------------------------------------------------------------
    PROCEDURE notify_sentinel(
        p_event_type   IN VARCHAR2,
        p_process_id   IN VARCHAR2,
        p_tenant_id    IN VARCHAR2,
        p_payload      IN CLOB DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_enqueue_options    DBMS_AQ.ENQUEUE_OPTIONS_T;
        l_message_properties DBMS_AQ.MESSAGE_PROPERTIES_T;
        l_message_handle     RAW(16);
        l_event              sentinel_event_t;
        l_tenant             VARCHAR2(50);
    BEGIN
        -- Resolve tenant ID
        IF p_tenant_id IS NULL THEN
            BEGIN
                SELECT tenant_id INTO l_tenant
                FROM process_live_status
                WHERE process_id = p_process_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    l_tenant := 'DEFAULT';
            END;
        ELSE
            l_tenant := p_tenant_id;
        END IF;
        
        l_event := sentinel_event_t(
            event_id      => RAWTOHEX(SYS_GUID()),
            event_type    => p_event_type,
            process_id    => p_process_id,
            tenant_id     => l_tenant,
            timestamp_utc => SYS_EXTRACT_UTC(SYSTIMESTAMP),
            payload       => p_payload
        );
        
        -- Set priority based on event type
        l_message_properties.priority := 
            CASE p_event_type
                WHEN c_event_error THEN 1
                WHEN c_event_completed THEN 2
                WHEN c_event_started THEN 3
                WHEN c_event_progress THEN 4
                ELSE 5
            END;
        
        DBMS_AQ.ENQUEUE(
            queue_name         => 'SENTINEL_QUEUE',
            enqueue_options    => l_enqueue_options,
            message_properties => l_message_properties,
            payload            => l_event,
            msgid              => l_message_handle
        );
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            -- Log but don't propagate queue errors
            NULL;
    END notify_sentinel;
    
    -- -------------------------------------------------------------------------
    -- Logging Procedures
    -- -------------------------------------------------------------------------
    
    PROCEDURE log_trace(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL
    ) IS
    BEGIN
        log_event(p_process_id, c_log_trace, p_message, NULL, NULL, p_details);
    END log_trace;
    
    PROCEDURE log_debug(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL
    ) IS
    BEGIN
        log_event(p_process_id, c_log_debug, p_message, NULL, NULL, p_details);
    END log_debug;
    
    PROCEDURE log_info(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL
    ) IS
    BEGIN
        log_event(p_process_id, c_log_info, p_message, NULL, NULL, p_details);
    END log_info;
    
    PROCEDURE log_warn(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL
    ) IS
    BEGIN
        log_event(p_process_id, c_log_warn, p_message, NULL, NULL, p_details);
    END log_warn;
    
    PROCEDURE log_error(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL,
        p_stack_trace IN CLOB DEFAULT NULL
    ) IS
    BEGIN
        log_event(p_process_id, c_log_error, p_message, NULL, NULL, p_details, p_stack_trace);
    END log_error;
    
    PROCEDURE log_fatal(
        p_process_id IN VARCHAR2,
        p_message    IN VARCHAR2,
        p_details    IN CLOB DEFAULT NULL,
        p_stack_trace IN CLOB DEFAULT NULL
    ) IS
    BEGIN
        log_event(p_process_id, c_log_fatal, p_message, NULL, NULL, p_details, p_stack_trace);
    END log_fatal;
    
    PROCEDURE log_event(
        p_process_id   IN VARCHAR2,
        p_log_level    IN VARCHAR2,
        p_message      IN VARCHAR2,
        p_event_type   IN VARCHAR2 DEFAULT NULL,
        p_component    IN VARCHAR2 DEFAULT NULL,
        p_details      IN CLOB DEFAULT NULL,
        p_stack_trace  IN CLOB DEFAULT NULL,
        p_correlation_id IN VARCHAR2 DEFAULT NULL
    ) IS
        l_tenant_id VARCHAR2(50);
    BEGIN
        -- Get tenant from process
        BEGIN
            SELECT tenant_id INTO l_tenant_id
            FROM process_live_status
            WHERE process_id = p_process_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                l_tenant_id := 'DEFAULT';
        END;
        
        insert_log(
            p_process_id     => p_process_id,
            p_tenant_id      => l_tenant_id,
            p_log_level      => p_log_level,
            p_message        => p_message,
            p_event_type     => p_event_type,
            p_component      => p_component,
            p_details        => p_details,
            p_stack_trace    => p_stack_trace,
            p_correlation_id => p_correlation_id
        );
    END log_event;
    
    -- -------------------------------------------------------------------------
    -- Utility Functions
    -- -------------------------------------------------------------------------
    
    FUNCTION get_status(
        p_process_id IN VARCHAR2
    ) RETURN VARCHAR2 IS
        l_status VARCHAR2(20);
    BEGIN
        SELECT status INTO l_status
        FROM process_live_status
        WHERE process_id = p_process_id;
        
        RETURN l_status;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END get_status;
    
    FUNCTION is_running(
        p_process_id IN VARCHAR2
    ) RETURN BOOLEAN IS
        l_status VARCHAR2(20);
    BEGIN
        l_status := get_status(p_process_id);
        -- Explicitly handle NULL: return FALSE if status is NULL or not RUNNING
        IF l_status IS NULL THEN
            RETURN FALSE;
        ELSE
            RETURN l_status = c_status_running;
        END IF;
    END is_running;

END sentinel_pkg;
/

-- =============================================================================
-- Grant Permissions
-- =============================================================================
GRANT EXECUTE ON sentinel_pkg TO clm_app;

-- Verify package compiled successfully
SELECT object_name, object_type, status
FROM user_objects
WHERE object_name = 'SENTINEL_PKG'
ORDER BY object_type;
