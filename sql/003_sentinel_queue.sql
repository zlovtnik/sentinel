-- =============================================================================
-- 003_sentinel_queue.sql
-- Oracle Advanced Queue (AQ) Setup for Process Sentinel
-- =============================================================================

-- =============================================================================
-- Create Queue Table
-- =============================================================================
BEGIN
    -- Drop existing queue infrastructure if present
    BEGIN
        DBMS_AQADM.STOP_QUEUE(queue_name => 'SENTINEL_QUEUE');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    
    BEGIN
        DBMS_AQADM.DROP_QUEUE(queue_name => 'SENTINEL_QUEUE');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    
    BEGIN
        DBMS_AQADM.DROP_QUEUE_TABLE(queue_table => 'SENTINEL_QUEUE_TAB', force => TRUE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END;
/

-- Create queue table with optimized settings
BEGIN
    DBMS_AQADM.CREATE_QUEUE_TABLE(
        queue_table        => 'SENTINEL_QUEUE_TAB',
        queue_payload_type => 'SENTINEL_EVENT_T',
        sort_list          => 'PRIORITY,ENQ_TIME',
        multiple_consumers => FALSE,        -- Single consumer (Sentinel service)
        message_grouping   => DBMS_AQADM.NONE,
        storage_clause     => 'TABLESPACE CLM_DATA
                              PCTFREE 10 PCTUSED 40
                              LOB(user_data.payload) STORE AS SECUREFILE (
                                  TABLESPACE CLM_DATA
                                  DISABLE STORAGE IN ROW
                                  COMPRESS HIGH
                              )',
        comment            => 'Queue table for Process Sentinel real-time events'
    );
END;
/

-- =============================================================================
-- Create the Queue
-- =============================================================================
BEGIN
    DBMS_AQADM.CREATE_QUEUE(
        queue_name      => 'SENTINEL_QUEUE',
        queue_table     => 'SENTINEL_QUEUE_TAB',
        max_retries     => 3,
        retry_delay     => 10,              -- 10 seconds between retries
        retention_time  => 86400,           -- Keep processed messages 1 day
        comment         => 'Process Sentinel real-time event queue'
    );
END;
/

-- =============================================================================
-- Start the Queue
-- =============================================================================
BEGIN
    DBMS_AQADM.START_QUEUE(
        queue_name  => 'SENTINEL_QUEUE',
        enqueue     => TRUE,
        dequeue     => TRUE
    );
END;
/

-- =============================================================================
-- Exception Queue (for failed messages)
-- =============================================================================
-- The exception queue is automatically created with name: AQ$_SENTINEL_QUEUE_TAB_E

-- =============================================================================
-- Grant Permissions
-- =============================================================================
-- Replace CLM_APP with your application schema

-- Grant execute on types
GRANT EXECUTE ON sentinel_event_t TO clm_app;

-- Grant AQ permissions (DBMS_AQ only - DBMS_AQADM is admin-only)
GRANT EXECUTE ON DBMS_AQ TO clm_app;
-- NOTE: DBMS_AQADM is NOT granted to application users for security
-- Administrative queue operations should be performed by DBA/admin roles

-- Grant queue privileges
BEGIN
    DBMS_AQADM.GRANT_QUEUE_PRIVILEGE(
        privilege     => 'ALL',
        queue_name    => 'SENTINEL_QUEUE',
        grantee       => 'CLM_APP',
        grant_option  => FALSE
    );
END;
/

-- =============================================================================
-- Create Dead Letter Queue for poison messages
-- =============================================================================
BEGIN
    DBMS_AQADM.CREATE_QUEUE(
        queue_name      => 'SENTINEL_DLQ',
        queue_table     => 'SENTINEL_QUEUE_TAB',
        max_retries     => 0,               -- No retries for DLQ
        comment         => 'Dead letter queue for failed sentinel events'
    );
    
    DBMS_AQADM.START_QUEUE(
        queue_name  => 'SENTINEL_DLQ',
        enqueue     => TRUE,
        dequeue     => TRUE
    );
    
    -- Grant DLQ privileges to application user
    DBMS_AQADM.GRANT_QUEUE_PRIVILEGE(
        privilege     => 'DEQUEUE',
        queue_name    => 'SENTINEL_DLQ',
        grantee       => 'CLM_APP',
        grant_option  => FALSE
    );
    
    DBMS_AQADM.GRANT_QUEUE_PRIVILEGE(
        privilege     => 'ENQUEUE',
        queue_name    => 'SENTINEL_DLQ',
        grantee       => 'CLM_APP',
        grant_option  => FALSE
    );
END;
/

-- =============================================================================
-- Helper Procedures for Queue Operations
-- =============================================================================

-- Procedure to move message to DLQ
-- NOTE: Uses AUTONOMOUS_TRANSACTION to ensure DLQ move completes independently
-- of the caller's transaction, preventing message loss on caller rollback
CREATE OR REPLACE PROCEDURE sentinel_move_to_dlq(
    p_msg_id IN RAW
) AS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_dequeue_options    DBMS_AQ.DEQUEUE_OPTIONS_T;
    l_message_properties DBMS_AQ.MESSAGE_PROPERTIES_T;
    l_enqueue_options    DBMS_AQ.ENQUEUE_OPTIONS_T;
    l_dequeued_msg_id    RAW(16);   -- Message ID from dequeue
    l_enqueue_msg_id     RAW(16);   -- New message ID for DLQ
    l_payload            sentinel_event_t;
BEGIN
    -- Dequeue by message ID
    l_dequeue_options.msgid := p_msg_id;
    l_dequeue_options.dequeue_mode := DBMS_AQ.REMOVE;
    l_dequeue_options.navigation := DBMS_AQ.FIRST_MESSAGE;
    l_dequeue_options.wait := DBMS_AQ.NO_WAIT;
    
    DBMS_AQ.DEQUEUE(
        queue_name         => 'SENTINEL_QUEUE',
        dequeue_options    => l_dequeue_options,
        message_properties => l_message_properties,
        payload            => l_payload,
        msgid              => l_dequeued_msg_id
    );
    
    -- Enqueue to DLQ with separate message handle
    DBMS_AQ.ENQUEUE(
        queue_name         => 'SENTINEL_DLQ',
        enqueue_options    => l_enqueue_options,
        message_properties => l_message_properties,
        payload            => l_payload,
        msgid              => l_enqueue_msg_id
    );
    
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END sentinel_move_to_dlq;
/

-- Procedure to purge old messages from queue
CREATE OR REPLACE PROCEDURE sentinel_purge_queue(
    p_hours_old IN NUMBER DEFAULT 24
) AS
    l_purge_options DBMS_AQADM.AQ$_PURGE_OPTIONS_T;
BEGIN
    -- Validate p_hours_old to prevent accidental full purge
    IF p_hours_old IS NULL OR p_hours_old <= 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 
            'sentinel_purge_queue: p_hours_old must be a positive number, got: ' || 
            NVL(TO_CHAR(p_hours_old), 'NULL'));
    END IF;
    
    l_purge_options.block := FALSE;
    
    DBMS_AQADM.PURGE_QUEUE_TABLE(
        queue_table     => 'SENTINEL_QUEUE_TAB',
        purge_condition => 'qtab.enq_time < SYSDATE - ' || p_hours_old || '/24',
        purge_options   => l_purge_options
    );
    
    DBMS_OUTPUT.PUT_LINE('Purged messages older than ' || p_hours_old || ' hours');
END sentinel_purge_queue;
/

-- =============================================================================
-- Queue Monitoring Views
-- =============================================================================

-- View for queue statistics
CREATE OR REPLACE VIEW v_sentinel_queue_stats AS
SELECT
    qt.name AS queue_name,
    qt.queue_type,
    qt.enqueue_enabled,
    qt.dequeue_enabled,
    qt.user_comment,
    (SELECT COUNT(*) FROM sentinel_queue_tab WHERE q_name = qt.name AND state = 0) AS waiting_count,
    (SELECT COUNT(*) FROM sentinel_queue_tab WHERE q_name = qt.name AND state = 1) AS ready_count,
    (SELECT COUNT(*) FROM sentinel_queue_tab WHERE q_name = qt.name AND state = 2) AS processed_count
FROM user_queues qt
WHERE qt.name IN ('SENTINEL_QUEUE', 'SENTINEL_DLQ');

-- View for recent queue activity
CREATE OR REPLACE VIEW v_sentinel_queue_activity AS
SELECT 
    msgid,
    q_name,
    state,
    CASE state 
        WHEN 0 THEN 'WAITING'
        WHEN 1 THEN 'READY'
        WHEN 2 THEN 'PROCESSED'
        WHEN 3 THEN 'EXPIRED'
    END AS state_desc,
    priority,
    enq_time,
    deq_time,
    retry_count,
    user_data.event_type AS event_type,
    user_data.process_id AS process_id,
    user_data.tenant_id AS tenant_id
FROM sentinel_queue_tab
WHERE enq_time > SYSDATE - 1  -- Last 24 hours
ORDER BY enq_time DESC;

-- =============================================================================
-- Verify Queue Setup
-- =============================================================================
SELECT 
    name AS queue_name,
    queue_type,
    enqueue_enabled,
    dequeue_enabled,
    max_retries,
    retry_delay
FROM user_queues 
WHERE name LIKE 'SENTINEL%'
ORDER BY name;
