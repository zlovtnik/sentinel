//! Oracle Advanced Queue (AQ) Listener
//! Provides real-time event dequeuing from Oracle AQ.

const std = @import("std");
const dpi = @import("../c_imports.zig");
const c = dpi.c;
const ConnectionPool = @import("connection.zig").ConnectionPool;

/// Sentinel event types matching PL/SQL constants
pub const EventType = enum {
    started,
    heartbeat,
    progress,
    completed,
    @"error",

    pub fn fromString(s: []const u8) ?EventType {
        const map = std.StaticStringMap(EventType).initComptime(.{
            .{ "STARTED", .started },
            .{ "HEARTBEAT", .heartbeat },
            .{ "PROGRESS", .progress },
            .{ "COMPLETED", .completed },
            .{ "ERROR", .@"error" },
        });
        return map.get(s);
    }

    pub fn toString(self: EventType) []const u8 {
        return switch (self) {
            .started => "STARTED",
            .heartbeat => "HEARTBEAT",
            .progress => "PROGRESS",
            .completed => "COMPLETED",
            .@"error" => "ERROR",
        };
    }
};

/// Sentinel event structure matching sentinel_event_t Oracle type
pub const SentinelEvent = struct {
    event_id: []const u8,
    event_type: EventType,
    process_id: []const u8,
    tenant_id: []const u8,
    timestamp_utc: i64,
    payload: ?[]const u8,

    pub fn format(
        self: SentinelEvent,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("Event[id={s}, type={s}, process={s}, tenant={s}]", .{
            self.event_id,
            self.event_type.toString(),
            self.process_id,
            self.tenant_id,
        });
    }
};

/// Event handler callback type
pub const EventHandler = *const fn (SentinelEvent, *std.mem.Allocator) void;

/// Oracle AQ Listener for real-time event streaming
pub const QueueListener = struct {
    pool: *ConnectionPool,
    queue_name: []const u8,
    object_type_name: []const u8,
    running: std.atomic.Value(bool),
    events_processed: std.atomic.Value(u64),
    errors_count: std.atomic.Value(u64),
    dequeue_wait_seconds: u32,

    const Self = @This();
    const DEFAULT_WAIT_SECONDS: u32 = 5;

    /// Initialize queue listener
    pub fn init(
        pool: *ConnectionPool,
        queue_name: []const u8,
        object_type_name: []const u8,
    ) Self {
        return .{
            .pool = pool,
            .queue_name = queue_name,
            .object_type_name = object_type_name,
            .running = std.atomic.Value(bool).init(false),
            .events_processed = std.atomic.Value(u64).init(0),
            .errors_count = std.atomic.Value(u64).init(0),
            .dequeue_wait_seconds = DEFAULT_WAIT_SECONDS,
        };
    }

    /// Start listening for events (blocking)
    pub fn listen(self: *Self, handler: EventHandler, allocator: *std.mem.Allocator) !void {
        self.running.store(true, .seq_cst);

        std.log.info("Starting AQ listener for queue: {s}", .{self.queue_name});

        while (self.running.load(.seq_cst)) {
            self.processNextEvent(handler, allocator) catch |err| {
                _ = self.errors_count.fetchAdd(1, .monotonic);
                std.log.err("Error processing event: {}", .{err});

                // Back off on errors
                std.time.sleep(std.time.ns_per_s);
            };
        }

        std.log.info("AQ listener stopped", .{});
    }

    /// Process a single event from the queue
    fn processNextEvent(self: *Self, handler: EventHandler, allocator: *std.mem.Allocator) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        // Get object type for sentinel_event_t
        var obj_type: ?*c.dpiObjectType = null;
        if (c.dpiConn_getObjectType(
            conn,
            self.object_type_name.ptr,
            @intCast(self.object_type_name.len),
            &obj_type,
        ) < 0) {
            return error.ObjectTypeLookupFailed;
        }
        defer _ = c.dpiObjectType_release(obj_type.?);

        // Create queue handle
        var queue: ?*c.dpiQueue = null;
        if (c.dpiConn_newQueue(
            conn,
            self.queue_name.ptr,
            @intCast(self.queue_name.len),
            obj_type,
            &queue,
        ) < 0) {
            return error.QueueCreationFailed;
        }
        defer _ = c.dpiQueue_release(queue.?);

        // Configure dequeue options
        var deq_options: ?*c.dpiDeqOptions = null;
        if (c.dpiQueue_getDeqOptions(queue.?, &deq_options) < 0) {
            return error.DequeueOperationFailed;
        }

        _ = c.dpiDeqOptions_setNavigation(deq_options.?, c.DPI_DEQ_NAV_FIRST_MSG);
        _ = c.dpiDeqOptions_setWait(deq_options.?, self.dequeue_wait_seconds);
        _ = c.dpiDeqOptions_setVisibility(deq_options.?, c.DPI_VISIBILITY_ON_COMMIT);

        // Attempt to dequeue
        var num_props: u32 = 1;
        var msg_props: [1]?*c.dpiMsgProps = .{null};

        const result = c.dpiQueue_deqMany(queue.?, &num_props, &msg_props);

        if (result < 0) {
            // Check if it's a timeout (no messages)
            const err = dpi.getErrorInfo(self.pool.context);
            if (err.code == 25228) { // ORA-25228: timeout in dequeue
                return; // Normal timeout, continue polling
            }
            std.log.warn("Dequeue error: {}", .{err});
            return error.DequeueOperationFailed;
        }

        if (num_props == 0 or msg_props[0] == null) {
            return; // No messages available
        }

        defer _ = c.dpiMsgProps_release(msg_props[0].?);

        // Extract event from message
        const event = try self.extractEvent(msg_props[0].?, allocator);

        // Call handler
        handler(event, allocator);

        // Commit the dequeue
        if (c.dpiConn_commit(conn) < 0) {
            return error.CommitFailed;
        }

        _ = self.events_processed.fetchAdd(1, .monotonic);
    }

    /// Extract SentinelEvent from Oracle message properties
    fn extractEvent(self: *Self, msg_props: *c.dpiMsgProps, allocator: *std.mem.Allocator) !SentinelEvent {
        _ = self;

        var payload: ?*c.dpiObject = null;
        if (c.dpiMsgProps_getPayload(msg_props, null, null, &payload) < 0) {
            return error.PayloadExtractionFailed;
        }

        if (payload == null) {
            return error.NullPayload;
        }

        // Extract fields from Oracle object
        // The object has these attributes: event_id, event_type, process_id, tenant_id, timestamp_utc, payload

        var event_id_data: c.dpiData = undefined;
        var event_type_data: c.dpiData = undefined;
        var process_id_data: c.dpiData = undefined;
        var tenant_id_data: c.dpiData = undefined;
        var timestamp_data: c.dpiData = undefined;
        var payload_data: c.dpiData = undefined;

        // Get attribute by index (matching sentinel_event_t structure)
        _ = c.dpiObject_getAttributeValue(payload.?, null, c.DPI_NATIVE_TYPE_BYTES, &event_id_data);
        _ = c.dpiObject_getAttributeValue(payload.?, null, c.DPI_NATIVE_TYPE_BYTES, &event_type_data);
        _ = c.dpiObject_getAttributeValue(payload.?, null, c.DPI_NATIVE_TYPE_BYTES, &process_id_data);
        _ = c.dpiObject_getAttributeValue(payload.?, null, c.DPI_NATIVE_TYPE_BYTES, &tenant_id_data);
        _ = c.dpiObject_getAttributeValue(payload.?, null, c.DPI_NATIVE_TYPE_TIMESTAMP, &timestamp_data);
        _ = c.dpiObject_getAttributeValue(payload.?, null, c.DPI_NATIVE_TYPE_LOB, &payload_data);

        const event_id = dpi.extractString(&event_id_data) orelse "";
        const event_type_str = dpi.extractString(&event_type_data) orelse "STARTED";
        const process_id = dpi.extractString(&process_id_data) orelse "";
        const tenant_id = dpi.extractString(&tenant_id_data) orelse "DEFAULT";

        // Copy strings to owned memory
        const owned_event_id = try allocator.dupe(u8, event_id);
        const owned_process_id = try allocator.dupe(u8, process_id);
        const owned_tenant_id = try allocator.dupe(u8, tenant_id);

        return .{
            .event_id = owned_event_id,
            .event_type = EventType.fromString(event_type_str) orelse .started,
            .process_id = owned_process_id,
            .tenant_id = owned_tenant_id,
            .timestamp_utc = std.time.timestamp(),
            .payload = null, // TODO: Extract CLOB payload
        };
    }

    /// Stop the listener
    pub fn stop(self: *Self) void {
        std.log.info("Stopping AQ listener...", .{});
        self.running.store(false, .seq_cst);
    }

    /// Get listener statistics
    pub fn getStats(self: *Self) ListenerStats {
        return .{
            .events_processed = self.events_processed.load(.monotonic),
            .errors = self.errors_count.load(.monotonic),
            .is_running = self.running.load(.monotonic),
        };
    }
};

/// Listener statistics
pub const ListenerStats = struct {
    events_processed: u64,
    errors: u64,
    is_running: bool,
};
