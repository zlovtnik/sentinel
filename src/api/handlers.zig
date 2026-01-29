//! Request Handlers
//! Business logic for API endpoints.

const std = @import("std");
const server = @import("server.zig");
const dpi = @import("../c_imports.zig");
const c = dpi.c;
const ConnectionPool = @import("../oracle/connection.zig").ConnectionPool;

/// Handler context passed to all handlers
pub const HandlerContext = struct {
    pool: *ConnectionPool,
    allocator: std.mem.Allocator,
    tenant_id: ?[]const u8,
    user_id: ?[]const u8,
    correlation_id: ?[]const u8,
};

/// Process status response structure
pub const ProcessStatusResponse = struct {
    process_id: []const u8,
    status: []const u8,
    current_step: ?[]const u8,
    progress_percent: ?f32,
    started_at: ?[]const u8,
    last_update_at: ?[]const u8,
    estimated_completion: ?[]const u8,
    metadata: ?[]const u8,

    pub fn toJson(self: ProcessStatusResponse, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        const writer = result.writer();

        try writer.writeAll("{");
        try writer.print("\"process_id\":\"{s}\",", .{self.process_id});
        try writer.print("\"status\":\"{s}\"", .{self.status});

        if (self.current_step) |step| {
            try writer.print(",\"current_step\":\"{s}\"", .{step});
        }

        if (self.progress_percent) |pct| {
            try writer.print(",\"progress_percent\":{d:.2}", .{pct});
        }

        if (self.started_at) |ts| {
            try writer.print(",\"started_at\":\"{s}\"", .{ts});
        }

        if (self.last_update_at) |ts| {
            try writer.print(",\"last_update_at\":\"{s}\"", .{ts});
        }

        try writer.writeAll("}");

        return result.toOwnedSlice();
    }
};

/// Query process status from database
pub fn queryProcessStatus(
    ctx: *HandlerContext,
    process_id: []const u8,
) !?ProcessStatusResponse {
    const conn = try ctx.pool.acquire();
    defer ctx.pool.release(conn);

    const sql =
        \\SELECT process_id, status, current_step, progress_percent,
        \\       TO_CHAR(started_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as started_at,
        \\       TO_CHAR(last_update_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as last_update_at
        \\FROM process_live_status
        \\WHERE process_id = :1 AND tenant_id = :2
    ;

    var stmt: ?*c.dpiStmt = null;
    if (c.dpiConn_prepareStmt(
        conn,
        0,
        sql.ptr,
        sql.len,
        null,
        0,
        &stmt,
    ) < 0) {
        return error.StatementPreparationFailed;
    }
    defer _ = c.dpiStmt_release(stmt.?);

    // Bind parameters
    var var_process_id: ?*c.dpiVar = null;
    var data_process_id: [*c]c.dpiData = undefined;
    if (c.dpiConn_newVar(
        conn,
        c.DPI_ORACLE_TYPE_VARCHAR,
        c.DPI_NATIVE_TYPE_BYTES,
        1,
        100,
        0,
        0,
        null,
        &var_process_id,
        &data_process_id,
    ) < 0) {
        return error.BindFailed;
    }
    defer _ = c.dpiVar_release(var_process_id.?);

    _ = c.dpiVar_setFromBytes(var_process_id.?, 0, process_id.ptr, @intCast(process_id.len));
    if (c.dpiStmt_bindByPos(stmt.?, 1, var_process_id.?) < 0) {
        return error.BindFailed;
    }

    // Bind tenant_id
    const tenant_id = ctx.tenant_id orelse "DEFAULT";
    var var_tenant_id: ?*c.dpiVar = null;
    var data_tenant_id: [*c]c.dpiData = undefined;
    if (c.dpiConn_newVar(
        conn,
        c.DPI_ORACLE_TYPE_VARCHAR,
        c.DPI_NATIVE_TYPE_BYTES,
        1,
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

    _ = c.dpiVar_setFromBytes(var_tenant_id.?, 0, tenant_id.ptr, @intCast(tenant_id.len));
    if (c.dpiStmt_bindByPos(stmt.?, 2, var_tenant_id.?) < 0) {
        return error.BindFailed;
    }

    // Execute
    var num_query_columns: u32 = 0;
    if (c.dpiStmt_execute(stmt.?, c.DPI_MODE_EXEC_DEFAULT, &num_query_columns) < 0) {
        return error.StatementExecutionFailed;
    }

    // Fetch results
    var found: c_int = 0;
    var buffer_row_index: u32 = 0;
    if (c.dpiStmt_fetch(stmt.?, &found, &buffer_row_index) < 0) {
        return error.FetchFailed;
    }

    if (found == 0) {
        return null;
    }

    // Extract column values
    var process_id_data: ?*c.dpiData = null;
    var native_type: c.dpiNativeTypeNum = 0;
    if (c.dpiStmt_getQueryValue(stmt.?, 1, &native_type, &process_id_data) < 0) {
        return error.FetchFailed;
    }

    var status_data: ?*c.dpiData = null;
    if (c.dpiStmt_getQueryValue(stmt.?, 2, &native_type, &status_data) < 0) {
        return error.FetchFailed;
    }

    const proc_id = dpi.extractString(process_id_data.?) orelse "";
    const status = dpi.extractString(status_data.?) orelse "UNKNOWN";

    return .{
        .process_id = try ctx.allocator.dupe(u8, proc_id),
        .status = try ctx.allocator.dupe(u8, status),
        .current_step = null,
        .progress_percent = null,
        .started_at = null,
        .last_update_at = null,
        .estimated_completion = null,
        .metadata = null,
    };
}

/// List active processes for a tenant
pub fn listActiveProcesses(
    ctx: *HandlerContext,
    limit: u32,
    offset: u32,
) ![]ProcessStatusResponse {
    _ = limit;
    _ = offset;

    const conn = try ctx.pool.acquire();
    defer ctx.pool.release(conn);

    // TODO: Implement pagination and filtering
    var results = std.ArrayList(ProcessStatusResponse).init(ctx.allocator);
    return results.toOwnedSlice();
}
