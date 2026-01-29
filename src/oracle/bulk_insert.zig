//! Bulk Insert Logger
//! Provides high-performance batch logging using Oracle array DML.

const std = @import("std");
const dpi = @import("../c_imports.zig");
const c = dpi.c;
const types = @import("types.zig");
const LogEntry = types.LogEntry;

/// Bulk logger for high-volume log insertion
pub const BulkLogger = struct {
    buffer: std.ArrayList(LogEntry),
    allocator: std.mem.Allocator,
    batch_size: usize,
    mutex: std.Thread.Mutex,

    // Metrics
    total_logged: std.atomic.Value(u64),
    total_flushed: std.atomic.Value(u64),
    flush_errors: std.atomic.Value(u64),

    const Self = @This();
    const DEFAULT_BATCH_SIZE: usize = 1000;

    const INSERT_SQL =
        \\INSERT INTO process_logs (
        \\    process_id, tenant_id, log_level, event_type, component,
        \\    message, details, stack_trace, correlation_id, span_id,
        \\    trace_id, event_duration_us, logged_at
        \\) VALUES (
        \\    :1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11, :12, SYSTIMESTAMP
        \\)
    ;

    /// Initialize bulk logger
    pub fn init(allocator: std.mem.Allocator, batch_size: ?usize) Self {
        return .{
            .buffer = std.ArrayList(LogEntry).init(allocator),
            .allocator = allocator,
            .batch_size = batch_size orelse DEFAULT_BATCH_SIZE,
            .mutex = .{},
            .total_logged = std.atomic.Value(u64).init(0),
            .total_flushed = std.atomic.Value(u64).init(0),
            .flush_errors = std.atomic.Value(u64).init(0),
        };
    }

    /// Add a log entry to the buffer
    pub fn log(self: *Self, entry: LogEntry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.buffer.append(entry);
        _ = self.total_logged.fetchAdd(1, .monotonic);

        // Auto-flush when batch size reached
        // Note: actual flush happens in separate flush() call with connection
    }

    /// Get current buffer size
    pub fn getBufferSize(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buffer.items.len;
    }

    /// Check if buffer should be flushed
    pub fn shouldFlush(self: *Self) bool {
        return self.getBufferSize() >= self.batch_size;
    }

    /// Flush buffer to database
    pub fn flush(self: *Self, conn: *c.dpiConn, context: *c.dpiContext) !usize {
        self.mutex.lock();
        const entries = self.buffer.toOwnedSlice() catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();

        if (entries.len == 0) {
            self.allocator.free(entries);
            return 0;
        }

        defer self.allocator.free(entries);

        const flushed = self.executeArrayInsert(conn, context, entries) catch |err| {
            _ = self.flush_errors.fetchAdd(1, .monotonic);
            std.log.err("Bulk insert failed: {}", .{err});
            return err;
        };

        _ = self.total_flushed.fetchAdd(flushed, .monotonic);
        return flushed;
    }

    /// Execute array DML insert
    fn executeArrayInsert(
        self: *Self,
        conn: *c.dpiConn,
        context: *c.dpiContext,
        entries: []const LogEntry,
    ) !usize {
        _ = self;

        const batch_count: u32 = @intCast(entries.len);

        // Prepare statement
        var stmt: ?*c.dpiStmt = null;
        if (c.dpiConn_prepareStmt(
            conn,
            0, // not scrollable
            INSERT_SQL.ptr,
            INSERT_SQL.len,
            null,
            0, // no tag
            &stmt,
        ) < 0) {
            return error.StatementPreparationFailed;
        }
        defer _ = c.dpiStmt_release(stmt.?);

        // Create variables for array binding
        // Variable 1: process_id (VARCHAR)
        var var_process_id: ?*c.dpiVar = null;
        var data_process_id: [*c]c.dpiData = undefined;
        if (c.dpiConn_newVar(
            conn,
            c.DPI_ORACLE_TYPE_VARCHAR,
            c.DPI_NATIVE_TYPE_BYTES,
            batch_count,
            100, // max size
            0,
            0,
            null,
            &var_process_id,
            &data_process_id,
        ) < 0) {
            return error.BindFailed;
        }
        defer _ = c.dpiVar_release(var_process_id.?);

        // Variable 2: tenant_id (VARCHAR)
        var var_tenant_id: ?*c.dpiVar = null;
        var data_tenant_id: [*c]c.dpiData = undefined;
        if (c.dpiConn_newVar(
            conn,
            c.DPI_ORACLE_TYPE_VARCHAR,
            c.DPI_NATIVE_TYPE_BYTES,
            batch_count,
            50,
            0,
            0,
            null,
            &var_tenant_id,
            &data_tenant_id,
        ) < 0) {
            return error.BindFailed;
        }
        defer _ = c.dpiVar_release(var_tenant_id.?);

        // Variable 3: log_level (VARCHAR)
        var var_log_level: ?*c.dpiVar = null;
        var data_log_level: [*c]c.dpiData = undefined;
        if (c.dpiConn_newVar(
            conn,
            c.DPI_ORACLE_TYPE_VARCHAR,
            c.DPI_NATIVE_TYPE_BYTES,
            batch_count,
            10,
            0,
            0,
            null,
            &var_log_level,
            &data_log_level,
        ) < 0) {
            return error.BindFailed;
        }
        defer _ = c.dpiVar_release(var_log_level.?);

        // Variable 4: event_type (VARCHAR, nullable)
        var var_event_type: ?*c.dpiVar = null;
        var data_event_type: [*c]c.dpiData = undefined;
        if (c.dpiConn_newVar(
            conn,
            c.DPI_ORACLE_TYPE_VARCHAR,
            c.DPI_NATIVE_TYPE_BYTES,
            batch_count,
            50,
            0,
            0,
            null,
            &var_event_type,
            &data_event_type,
        ) < 0) {
            return error.BindFailed;
        }
        defer _ = c.dpiVar_release(var_event_type.?);

        // Variable 5: component (VARCHAR, nullable)
        var var_component: ?*c.dpiVar = null;
        var data_component: [*c]c.dpiData = undefined;
        if (c.dpiConn_newVar(
            conn,
            c.DPI_ORACLE_TYPE_VARCHAR,
            c.DPI_NATIVE_TYPE_BYTES,
            batch_count,
            100,
            0,
            0,
            null,
            &var_component,
            &data_component,
        ) < 0) {
            return error.BindFailed;
        }
        defer _ = c.dpiVar_release(var_component.?);

        // Variable 6: message (VARCHAR)
        var var_message: ?*c.dpiVar = null;
        var data_message: [*c]c.dpiData = undefined;
        if (c.dpiConn_newVar(
            conn,
            c.DPI_ORACLE_TYPE_VARCHAR,
            c.DPI_NATIVE_TYPE_BYTES,
            batch_count,
            4000,
            0,
            0,
            null,
            &var_message,
            &data_message,
        ) < 0) {
            return error.BindFailed;
        }
        defer _ = c.dpiVar_release(var_message.?);

        // Populate arrays with data
        for (entries, 0..) |entry, i| {
            const idx: u32 = @intCast(i);

            // process_id
            _ = c.dpiVar_setFromBytes(var_process_id.?, idx, entry.process_id.ptr, @intCast(entry.process_id.len));

            // tenant_id
            _ = c.dpiVar_setFromBytes(var_tenant_id.?, idx, entry.tenant_id.ptr, @intCast(entry.tenant_id.len));

            // log_level
            const level_str = entry.log_level.toString();
            _ = c.dpiVar_setFromBytes(var_log_level.?, idx, level_str.ptr, @intCast(level_str.len));

            // event_type
            if (entry.event_type) |et| {
                _ = c.dpiVar_setFromBytes(var_event_type.?, idx, et.ptr, @intCast(et.len));
            } else {
                data_event_type[i].isNull = 1;
            }

            // component
            if (entry.component) |comp| {
                _ = c.dpiVar_setFromBytes(var_component.?, idx, comp.ptr, @intCast(comp.len));
            } else {
                data_component[i].isNull = 1;
            }

            // message
            _ = c.dpiVar_setFromBytes(var_message.?, idx, entry.message.ptr, @intCast(entry.message.len));
        }

        // Bind variables to statement
        if (c.dpiStmt_bindByPos(stmt.?, 1, var_process_id.?) < 0) return error.BindFailed;
        if (c.dpiStmt_bindByPos(stmt.?, 2, var_tenant_id.?) < 0) return error.BindFailed;
        if (c.dpiStmt_bindByPos(stmt.?, 3, var_log_level.?) < 0) return error.BindFailed;
        if (c.dpiStmt_bindByPos(stmt.?, 4, var_event_type.?) < 0) return error.BindFailed;
        if (c.dpiStmt_bindByPos(stmt.?, 5, var_component.?) < 0) return error.BindFailed;
        if (c.dpiStmt_bindByPos(stmt.?, 6, var_message.?) < 0) return error.BindFailed;

        // Execute array DML
        if (c.dpiStmt_executeMany(stmt.?, c.DPI_MODE_EXEC_DEFAULT, batch_count) < 0) {
            const err = dpi.getErrorInfo(context);
            std.log.err("executeMany failed: {}", .{err});
            return error.StatementExecutionFailed;
        }

        // Commit
        if (c.dpiConn_commit(conn) < 0) {
            return error.CommitFailed;
        }

        var row_count: u64 = 0;
        _ = c.dpiStmt_getRowCount(stmt.?, &row_count);

        std.log.debug("Flushed {d} log entries", .{row_count});
        return @intCast(row_count);
    }

    /// Get logger statistics
    pub fn getStats(self: *Self) LoggerStats {
        return .{
            .buffered = self.getBufferSize(),
            .total_logged = self.total_logged.load(.monotonic),
            .total_flushed = self.total_flushed.load(.monotonic),
            .flush_errors = self.flush_errors.load(.monotonic),
        };
    }

    /// Cleanup
    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }
};

/// Logger statistics
pub const LoggerStats = struct {
    buffered: usize,
    total_logged: u64,
    total_flushed: u64,
    flush_errors: u64,
};
