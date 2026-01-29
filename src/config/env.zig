//! Environment Configuration Loader
//! Loads all configuration from environment variables for 12-factor compliance.

const std = @import("std");
const dpi = @import("../c_imports.zig");
const c = dpi.c;

/// Complete application configuration loaded from environment
pub const Config = struct {
    // =========================================================================
    // Oracle Database Configuration
    // =========================================================================
    wallet_location: []const u8,
    tns_name: []const u8,
    username: []const u8,
    password: []const u8,

    // =========================================================================
    // OAuth2 / Keycloak Configuration
    // =========================================================================
    jwk_set_uri: []const u8,
    issuer_uri: []const u8,
    audience: []const u8,

    // =========================================================================
    // Sentinel-Specific Configuration
    // =========================================================================
    http_port: u16,
    worker_threads: usize,
    queue_name: []const u8,
    queue_event_type: []const u8,
    log_batch_size: usize,
    heartbeat_interval_sec: u32,
    process_timeout_sec: u32,

    // =========================================================================
    // Connection Pool Configuration
    // =========================================================================
    pool_min_sessions: u32,
    pool_max_sessions: u32,
    pool_session_increment: u32,
    pool_ping_interval: i32,
    pool_wait_timeout: u32,
    pool_timeout: i32,
    pool_get_mode: u8,
    pool_max_lifetime_session: u32,

    // =========================================================================
    // Telemetry Configuration
    // =========================================================================
    otel_endpoint: ?[]const u8,
    metrics_port: u16,
    log_level: LogLevel,

    /// Supported log levels
    pub const LogLevel = enum {
        trace,
        debug,
        info,
        warn,
        err,
        fatal,

        pub fn fromString(s: []const u8) LogLevel {
            const map = std.StaticStringMap(LogLevel).initComptime(.{
                .{ "trace", .trace },
                .{ "debug", .debug },
                .{ "info", .info },
                .{ "warn", .warn },
                .{ "error", .err },
                .{ "fatal", .fatal },
            });
            return map.get(s) orelse .info;
        }
    };

    /// Load configuration from environment variables
    pub fn load() !Config {
        return .{
            // Oracle
            .wallet_location = std.posix.getenv("ORACLE_WALLET_LOCATION") orelse
                return error.MissingWalletLocation,
            .tns_name = std.posix.getenv("ORACLE_TNS_NAME") orelse
                return error.MissingTnsName,
            .username = std.posix.getenv("ORACLE_USERNAME") orelse
                return error.MissingUsername,
            .password = std.posix.getenv("ORACLE_PASSWORD") orelse "",

            // OAuth2
            .jwk_set_uri = std.posix.getenv("OAUTH2_JWK_SET_URI") orelse
                return error.MissingJwkUri,
            .issuer_uri = std.posix.getenv("OAUTH2_ISSUER_URI") orelse
                return error.MissingIssuerUri,
            .audience = std.posix.getenv("OAUTH2_AUDIENCE") orelse "clm-service",

            // Sentinel
            .http_port = parseU16("SENTINEL_HTTP_PORT", 8090),
            .worker_threads = parseUsize("SENTINEL_WORKER_THREADS", 4),
            .queue_name = std.posix.getenv("SENTINEL_QUEUE_NAME") orelse "SENTINEL_QUEUE",
            .queue_event_type = std.posix.getenv("SENTINEL_QUEUE_EVENT_TYPE") orelse "SENTINEL_EVENT_T",
            .log_batch_size = parseUsize("SENTINEL_LOG_BATCH_SIZE", 1000),
            .heartbeat_interval_sec = parseU32("SENTINEL_HEARTBEAT_INTERVAL_SEC", 30),
            .process_timeout_sec = parseU32("SENTINEL_PROCESS_TIMEOUT_SEC", 3600),

            // Connection Pool
            .pool_min_sessions = parseU32("SENTINEL_POOL_MIN_SESSIONS", 2),
            .pool_max_sessions = parseU32("SENTINEL_POOL_MAX_SESSIONS", 10),
            .pool_session_increment = parseU32("SENTINEL_POOL_SESSION_INCREMENT", 1),
            .pool_ping_interval = parseI32("SENTINEL_POOL_PING_INTERVAL", 60),
            .pool_wait_timeout = parseU32("SENTINEL_POOL_WAIT_TIMEOUT", 5000),
            .pool_timeout = parseI32("SENTINEL_POOL_TIMEOUT", 5000),
            .pool_get_mode = parsePoolGetMode("SENTINEL_POOL_GET_MODE", @intCast(c.DPI_MODE_POOL_GET_TIMEDWAIT)),
            .pool_max_lifetime_session = parseU32("SENTINEL_POOL_MAX_LIFETIME_SESSION", 3600),

            // Telemetry
            .otel_endpoint = std.posix.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
            .metrics_port = parseU16("PROMETHEUS_METRICS_PORT", 9090),
            .log_level = LogLevel.fromString(std.posix.getenv("LOG_LEVEL") orelse "info"),
        };
    }

    /// Print configuration summary (masks sensitive values)
    pub fn printSummary(self: Config) void {
        std.log.info("=== Process Sentinel Configuration ===", .{});
        std.log.info("Oracle TNS Name: {s}", .{self.tns_name});
        std.log.info("Oracle Username: {s}", .{self.username});
        std.log.info("Oracle Wallet: {s}", .{self.wallet_location});
        std.log.info("HTTP Port: {d}", .{self.http_port});
        std.log.info("Worker Threads: {d}", .{self.worker_threads});
        std.log.info("Queue Name: {s}", .{self.queue_name});
        std.log.info("Pool Size: {d}-{d}", .{ self.pool_min_sessions, self.pool_max_sessions });
        std.log.info("Metrics Port: {d}", .{self.metrics_port});
        if (self.otel_endpoint) |ep| {
            std.log.info("OTEL Endpoint: {s}", .{ep});
        }
        std.log.info("======================================", .{});
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

fn parseU16(name: []const u8, default: u16) u16 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u16, val, 10) catch default;
}

fn parseU32(name: []const u8, default: u32) u32 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u32, val, 10) catch default;
}

fn parseI32(name: []const u8, default: i32) i32 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(i32, val, 10) catch default;
}

fn parseUsize(name: []const u8, default: usize) usize {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(usize, val, 10) catch default;
}

fn parsePoolGetMode(name: []const u8, default: u8) u8 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u8, val, 10) catch default;
}

// =============================================================================
// Tests
// =============================================================================

test "Config.LogLevel.fromString parses levels" {
    try std.testing.expectEqual(Config.LogLevel.debug, Config.LogLevel.fromString("debug"));
    try std.testing.expectEqual(Config.LogLevel.info, Config.LogLevel.fromString("unknown"));
}
