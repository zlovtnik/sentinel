//! Oracle Type Mappings
//! Maps between Zig types and Oracle/ODPI-C types.

const std = @import("std");
const dpi = @import("../c_imports.zig");
const c = dpi.c;

/// Oracle native types
pub const OracleType = enum(c_uint) {
    varchar = c.DPI_ORACLE_TYPE_VARCHAR,
    number = c.DPI_ORACLE_TYPE_NUMBER,
    date = c.DPI_ORACLE_TYPE_DATE,
    timestamp = c.DPI_ORACLE_TYPE_TIMESTAMP,
    timestamp_tz = c.DPI_ORACLE_TYPE_TIMESTAMP_TZ,
    timestamp_ltz = c.DPI_ORACLE_TYPE_TIMESTAMP_LTZ,
    clob = c.DPI_ORACLE_TYPE_CLOB,
    blob = c.DPI_ORACLE_TYPE_BLOB,
    raw = c.DPI_ORACLE_TYPE_RAW,
    object = c.DPI_ORACLE_TYPE_OBJECT,
    json = c.DPI_ORACLE_TYPE_JSON,
    boolean = c.DPI_ORACLE_TYPE_BOOLEAN,
};

/// Zig native type mapping
pub const NativeType = enum(c_uint) {
    bytes = c.DPI_NATIVE_TYPE_BYTES,
    int64 = c.DPI_NATIVE_TYPE_INT64,
    uint64 = c.DPI_NATIVE_TYPE_UINT64,
    float = c.DPI_NATIVE_TYPE_FLOAT,
    double = c.DPI_NATIVE_TYPE_DOUBLE,
    timestamp = c.DPI_NATIVE_TYPE_TIMESTAMP,
    lob = c.DPI_NATIVE_TYPE_LOB,
    object = c.DPI_NATIVE_TYPE_OBJECT,
    boolean = c.DPI_NATIVE_TYPE_BOOLEAN,
    json = c.DPI_NATIVE_TYPE_JSON,
};

/// Process status values
pub const ProcessStatus = enum {
    registered,
    active,
    running,
    paused,
    completed,
    failed,
    expired,
    archived,

    pub fn fromString(s: []const u8) ?ProcessStatus {
        const map = std.StaticStringMap(ProcessStatus).initComptime(.{
            .{ "REGISTERED", .registered },
            .{ "ACTIVE", .active },
            .{ "RUNNING", .running },
            .{ "PAUSED", .paused },
            .{ "COMPLETED", .completed },
            .{ "FAILED", .failed },
            .{ "EXPIRED", .expired },
            .{ "ARCHIVED", .archived },
        });
        return map.get(s);
    }

    pub fn toString(self: ProcessStatus) []const u8 {
        return switch (self) {
            .registered => "REGISTERED",
            .active => "ACTIVE",
            .running => "RUNNING",
            .paused => "PAUSED",
            .completed => "COMPLETED",
            .failed => "FAILED",
            .expired => "EXPIRED",
            .archived => "ARCHIVED",
        };
    }
};

/// Log level values
pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    @"error",
    fatal,

    pub fn fromString(s: []const u8) ?LogLevel {
        const map = std.StaticStringMap(LogLevel).initComptime(.{
            .{ "TRACE", .trace },
            .{ "DEBUG", .debug },
            .{ "INFO", .info },
            .{ "WARN", .warn },
            .{ "ERROR", .@"error" },
            .{ "FATAL", .fatal },
        });
        return map.get(s);
    }

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .@"error" => "ERROR",
            .fatal => "FATAL",
        };
    }
};

/// Process registry record
pub const ProcessRecord = struct {
    process_id: []const u8,
    process_uuid: [16]u8,
    process_type: []const u8,
    process_name: []const u8,
    package_name: ?[]const u8,
    procedure_name: ?[]const u8,
    tenant_id: []const u8,
    owner_service: []const u8,
    status: ProcessStatus,
    registered_at: i64,
    last_heartbeat_at: ?i64,
    total_executions: u64,
    successful_runs: u64,
    failed_runs: u64,
    avg_duration_ms: ?f64,
};

/// Live process status
pub const LiveStatus = struct {
    process_id: []const u8,
    tenant_id: []const u8,
    status: ProcessStatus,
    started_at: ?i64,
    current_step: ?[]const u8,
    progress_percent: ?f32,
    last_update_at: i64,
    estimated_completion: ?i64,
    metadata: ?[]const u8,
};

/// Log entry for bulk insertion
pub const LogEntry = struct {
    process_id: []const u8,
    tenant_id: []const u8,
    log_level: LogLevel,
    event_type: ?[]const u8,
    component: ?[]const u8,
    message: []const u8,
    details_json: ?[]const u8,
    stack_trace: ?[]const u8,
    correlation_id: ?[]const u8,
    span_id: ?[]const u8,
    trace_id: ?[]const u8,
    event_duration_us: ?i64,
};

/// Oracle timestamp structure
pub const OracleTimestamp = struct {
    year: i16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    fsecond: u32,
    tz_hour_offset: i8,
    tz_minute_offset: i8,

    /// Convert to Unix timestamp (seconds since epoch)
    pub fn toUnixTimestamp(self: OracleTimestamp) i64 {
        // Simplified conversion - in production use proper calendar math
        const days_since_epoch = self.daysSinceEpoch();
        const seconds_in_day = @as(i64, self.hour) * 3600 +
            @as(i64, self.minute) * 60 +
            @as(i64, self.second);
        return days_since_epoch * 86400 + seconds_in_day;
    }

    fn daysSinceEpoch(self: OracleTimestamp) i64 {
        // Simplified - doesn't handle all edge cases
        var days: i64 = 0;
        var y: i16 = 1970;
        while (y < self.year) : (y += 1) {
            days += if (isLeapYear(y)) 366 else 365;
        }
        // Add days for months
        const days_per_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var m: u8 = 1;
        while (m < self.month) : (m += 1) {
            days += days_per_month[m - 1];
            if (m == 2 and isLeapYear(self.year)) days += 1;
        }
        days += self.day - 1;
        return days;
    }

    fn isLeapYear(year: i16) bool {
        return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    }

    /// Create from dpiTimestamp
    pub fn fromDpi(ts: c.dpiTimestamp) OracleTimestamp {
        return .{
            .year = ts.year,
            .month = ts.month,
            .day = ts.day,
            .hour = ts.hour,
            .minute = ts.minute,
            .second = ts.second,
            .fsecond = ts.fsecond,
            .tz_hour_offset = ts.tzHourOffset,
            .tz_minute_offset = ts.tzMinuteOffset,
        };
    }
};
