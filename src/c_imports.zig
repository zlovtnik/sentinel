//! C Imports for ODPI-C (Oracle Database Programming Interface for C)
//! This module provides Zig-friendly wrappers around ODPI-C types and functions.

pub const c = @cImport({
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cInclude("dpi.h");
});

const std = @import("std");

// =============================================================================
// Type Aliases for Clarity
// =============================================================================

pub const DpiContext = c.dpiContext;
pub const DpiPool = c.dpiPool;
pub const DpiConn = c.dpiConn;
pub const DpiStmt = c.dpiStmt;
pub const DpiDeqOptions = c.dpiDeqOptions;
pub const DpiEnqOptions = c.dpiEnqOptions;
pub const DpiMsgProps = c.dpiMsgProps;
pub const DpiQueue = c.dpiQueue;
pub const DpiObject = c.dpiObject;
pub const DpiObjectType = c.dpiObjectType;
pub const DpiVar = c.dpiVar;
pub const DpiData = c.dpiData;
pub const DpiLob = c.dpiLob;

// =============================================================================
// Constants
// =============================================================================

pub const DPI_SUCCESS = c.DPI_SUCCESS;
pub const DPI_FAILURE = c.DPI_FAILURE;

pub const DPI_MODE_EXEC_DEFAULT = c.DPI_MODE_EXEC_DEFAULT;
pub const DPI_MODE_EXEC_COMMIT_ON_SUCCESS = c.DPI_MODE_EXEC_COMMIT_ON_SUCCESS;

pub const DPI_MODE_POOL_GET_WAIT = c.DPI_MODE_POOL_GET_WAIT;
pub const DPI_MODE_POOL_GET_NOWAIT = c.DPI_MODE_POOL_GET_NOWAIT;
pub const DPI_MODE_POOL_GET_FORCEGET = c.DPI_MODE_POOL_GET_FORCEGET;
pub const DPI_MODE_POOL_GET_TIMEDWAIT = c.DPI_MODE_POOL_GET_TIMEDWAIT;

pub const DPI_DEQ_NAV_FIRST_MSG = c.DPI_DEQ_NAV_FIRST_MSG;
pub const DPI_DEQ_NAV_NEXT_MSG = c.DPI_DEQ_NAV_NEXT_MSG;
pub const DPI_DEQ_NAV_NEXT_TRANSACTION = c.DPI_DEQ_NAV_NEXT_TRANSACTION;

pub const DPI_VISIBILITY_IMMEDIATE = c.DPI_VISIBILITY_IMMEDIATE;
pub const DPI_VISIBILITY_ON_COMMIT = c.DPI_VISIBILITY_ON_COMMIT;

pub const DPI_DEQ_WAIT_FOREVER = c.DPI_DEQ_WAIT_FOREVER;
pub const DPI_DEQ_NO_WAIT = c.DPI_DEQ_NO_WAIT;

pub const DPI_ORACLE_TYPE_VARCHAR = c.DPI_ORACLE_TYPE_VARCHAR;
pub const DPI_ORACLE_TYPE_NUMBER = c.DPI_ORACLE_TYPE_NUMBER;
pub const DPI_ORACLE_TYPE_TIMESTAMP = c.DPI_ORACLE_TYPE_TIMESTAMP;
pub const DPI_ORACLE_TYPE_CLOB = c.DPI_ORACLE_TYPE_CLOB;
pub const DPI_ORACLE_TYPE_OBJECT = c.DPI_ORACLE_TYPE_OBJECT;
pub const DPI_ORACLE_TYPE_JSON = c.DPI_ORACLE_TYPE_JSON;

pub const DPI_NATIVE_TYPE_BYTES = c.DPI_NATIVE_TYPE_BYTES;
pub const DPI_NATIVE_TYPE_DOUBLE = c.DPI_NATIVE_TYPE_DOUBLE;
pub const DPI_NATIVE_TYPE_INT64 = c.DPI_NATIVE_TYPE_INT64;
pub const DPI_NATIVE_TYPE_TIMESTAMP = c.DPI_NATIVE_TYPE_TIMESTAMP;
pub const DPI_NATIVE_TYPE_LOB = c.DPI_NATIVE_TYPE_LOB;
pub const DPI_NATIVE_TYPE_OBJECT = c.DPI_NATIVE_TYPE_OBJECT;

// =============================================================================
// Error Handling
// =============================================================================

pub const DpiError = struct {
    code: i32,
    message: []const u8,
    fn_name: []const u8,
    action: []const u8,
    sql_state: [6]u8,
    is_recoverable: bool,
    is_warning: bool,

    pub fn format(
        self: DpiError,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("ORA-{d}: {s} (fn: {s}, recoverable: {any})", .{
            self.code,
            self.message,
            self.fn_name,
            self.is_recoverable,
        });
    }
};

pub fn getErrorInfo(context: *DpiContext) DpiError {
    var err_info: c.dpiErrorInfo = undefined;
    c.dpiContext_getError(context, &err_info);

    const msg_len = if (err_info.messageLength > 0) err_info.messageLength else 0;
    const fn_len = std.mem.len(err_info.fnName);
    const action_len = std.mem.len(err_info.action);

    return .{
        .code = err_info.code,
        .message = if (msg_len > 0) err_info.message[0..msg_len] else "",
        .fn_name = if (fn_len > 0) err_info.fnName[0..fn_len] else "",
        .action = if (action_len > 0) err_info.action[0..action_len] else "",
        .sql_state = err_info.sqlState[0..6].*,
        .is_recoverable = err_info.isRecoverable != 0,
        .is_warning = err_info.isWarning != 0,
    };
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Convert a Zig slice to ODPI-C compatible pointer and length
pub fn toOracleString(s: []const u8) struct { ptr: [*c]const u8, len: u32 } {
    return .{
        .ptr = s.ptr,
        .len = @intCast(s.len),
    };
}

/// Extract string from DpiData bytes
pub fn extractString(data: *c.dpiData) ?[]const u8 {
    if (data.isNull != 0) return null;
    const bytes = data.value.asBytes;
    if (bytes.length == 0) return "";
    return bytes.ptr[0..bytes.length];
}

/// Extract i64 from DpiData
pub fn extractInt64(data: *c.dpiData) ?i64 {
    if (data.isNull != 0) return null;
    return data.value.asInt64;
}

/// Extract f64 from DpiData
pub fn extractDouble(data: *c.dpiData) ?f64 {
    if (data.isNull != 0) return null;
    return data.value.asDouble;
}

// =============================================================================
// Common ODPI-C Wrappers
// =============================================================================

pub const OdpiError = error{
    ContextCreationFailed,
    PoolCreationFailed,
    ConnectionAcquisitionFailed,
    ConnectionReleaseFailed,
    StatementPreparationFailed,
    StatementExecutionFailed,
    BindFailed,
    DefineFailed,
    FetchFailed,
    CommitFailed,
    RollbackFailed,
    QueueCreationFailed,
    DequeueOperationFailed,
    EnqueueOperationFailed,
    ObjectTypeLookupFailed,
    ObjectCreationFailed,
    LobOperationFailed,
};

/// Check ODPI-C return value and convert to Zig error
pub fn checkResult(result: c_int, context: *DpiContext, comptime err_to_return: OdpiError) OdpiError!void {
    if (result < 0) {
        const err = getErrorInfo(context);
        std.log.err("ODPI-C error: {any}", .{err});
        return err_to_return;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "toOracleString works correctly" {
    const str = "Hello, Oracle!";
    const result = toOracleString(str);
    try std.testing.expectEqual(@as(u32, 14), result.len);
}
