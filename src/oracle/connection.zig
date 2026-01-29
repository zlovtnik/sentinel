//! Oracle Connection Pool
//! Provides high-performance connection pooling using ODPI-C.

const std = @import("std");
const dpi = @import("../c_imports.zig");
const c = dpi.c;
const WalletConfig = @import("../config/wallet.zig").WalletConfig;

/// Connection Pool configuration
pub const PoolConfig = struct {
    min_sessions: u32 = 2,
    max_sessions: u32 = 10,
    session_increment: u32 = 1,
    ping_interval: i32 = 60,
    timeout: i32 = 0,
    wait_timeout: u32 = 5000,
    max_lifetime_session: u32 = 3600,
    get_mode: u8 = @intCast(c.DPI_MODE_POOL_GET_TIMEDWAIT),
};

/// Thread-safe Oracle connection pool
pub const ConnectionPool = struct {
    context: *c.dpiContext,
    pool: *c.dpiPool,
    config: PoolConfig,
    conn_string: []const u8,

    // Metrics
    acquired_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    released_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    error_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const Self = @This();

    /// Initialize connection pool
    pub fn init(
        wallet: WalletConfig,
        username: []const u8,
        password: []const u8,
        pool_config: PoolConfig,
        allocator: std.mem.Allocator,
    ) !Self {
        var context: ?*c.dpiContext = null;
        var err_info: c.dpiErrorInfo = undefined;

        // Create ODPI-C context
        if (c.dpiContext_createWithParams(
            c.DPI_MAJOR_VERSION,
            c.DPI_MINOR_VERSION,
            null,
            &context,
            &err_info,
        ) < 0) {
            std.log.err("Failed to create ODPI-C context: {s}", .{
                err_info.message[0..@intCast(err_info.messageLength)],
            });
            return error.ContextCreationFailed;
        }

        const ctx = context.?;

        // Build connection descriptor
        const conn_str = try wallet.getConnectionDescriptor(allocator);

        // Pool creation parameters
        var create_params: c.dpiPoolCreateParams = undefined;
        _ = c.dpiContext_initPoolCreateParams(ctx, &create_params);

        create_params.minSessions = pool_config.min_sessions;
        create_params.maxSessions = pool_config.max_sessions;
        create_params.sessionIncrement = pool_config.session_increment;
        create_params.pingInterval = pool_config.ping_interval;
        create_params.pingTimeout = pool_config.timeout;
        create_params.getMode = pool_config.get_mode;
        create_params.timeout = pool_config.wait_timeout;
        create_params.maxLifetimeSession = pool_config.max_lifetime_session;
        create_params.homogeneous = 1; // All connections use same credentials

        var pool: ?*c.dpiPool = null;

        std.log.info("Creating Oracle connection pool...", .{});
        std.log.debug("  Connection: {s}", .{conn_str});
        std.log.debug("  Username: {s}", .{username});
        std.log.info("  Pool size: {d}-{d}", .{ pool_config.min_sessions, pool_config.max_sessions });

        if (c.dpiPool_create(
            ctx,
            username.ptr,
            @intCast(username.len),
            password.ptr,
            @intCast(password.len),
            conn_str.ptr,
            @intCast(conn_str.len),
            null, // common params (use defaults)
            &create_params,
            &pool,
        ) < 0) {
            const pool_err = dpi.getErrorInfo(ctx);
            std.log.err("Failed to create connection pool: {any}", .{pool_err});
            _ = c.dpiContext_destroy(ctx);
            return error.PoolCreationFailed;
        }

        std.log.info("Oracle connection pool created successfully", .{});

        return .{
            .context = ctx,
            .pool = pool.?,
            .config = pool_config,
            .conn_string = conn_str,
        };
    }

    /// Acquire a connection from the pool
    pub fn acquire(self: *Self) !*c.dpiConn {
        var conn: ?*c.dpiConn = null;

        if (c.dpiPool_acquireConnection(
            self.pool,
            null,
            0, // username (use pool credentials)
            null,
            0, // password
            null, // connection params
            &conn,
        ) < 0) {
            _ = self.error_count.fetchAdd(1, .monotonic);
            const err = dpi.getErrorInfo(self.context);
            std.log.err("Failed to acquire connection: {any}", .{err});
            return error.ConnectionAcquisitionFailed;
        }

        _ = self.acquired_count.fetchAdd(1, .monotonic);
        return conn.?;
    }

    /// Release a connection back to the pool
    pub fn release(self: *Self, conn: *c.dpiConn) void {
        _ = c.dpiConn_release(conn);
        _ = self.released_count.fetchAdd(1, .monotonic);
    }

    /// Get current pool statistics
    pub fn getStats(self: *Self) PoolStats {
        var open_count: u32 = 0;
        var busy_count: u32 = 0;

        _ = c.dpiPool_getOpenCount(self.pool, &open_count);
        _ = c.dpiPool_getBusyCount(self.pool, &busy_count);

        return .{
            .open_connections = open_count,
            .busy_connections = busy_count,
            .available_connections = if (open_count > busy_count) open_count - busy_count else 0,
            .total_acquired = self.acquired_count.load(.monotonic),
            .total_released = self.released_count.load(.monotonic),
            .total_errors = self.error_count.load(.monotonic),
        };
    }

    /// Close pool and release all resources
    pub fn deinit(self: *Self) void {
        std.log.info("Closing Oracle connection pool...", .{});
        _ = c.dpiPool_close(self.pool, c.DPI_MODE_POOL_CLOSE_DEFAULT);
        _ = c.dpiPool_release(self.pool);
        _ = c.dpiContext_destroy(self.context);
        std.log.info("Oracle connection pool closed", .{});
    }
};

/// Pool statistics
pub const PoolStats = struct {
    open_connections: u32,
    busy_connections: u32,
    available_connections: u32,
    total_acquired: u64,
    total_released: u64,
    total_errors: u64,

    pub fn format(
        self: PoolStats,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("Pool[open={d}, busy={d}, avail={d}, acquired={d}, released={d}, errors={d}]", .{
            self.open_connections,
            self.busy_connections,
            self.available_connections,
            self.total_acquired,
            self.total_released,
            self.total_errors,
        });
    }
};

/// RAII wrapper for connection lifecycle
pub const PooledConnection = struct {
    conn: *c.dpiConn,
    pool: *ConnectionPool,

    pub fn deinit(self: *PooledConnection) void {
        self.pool.release(self.conn);
    }
};

/// Acquire a connection with RAII semantics
pub fn acquireScoped(pool: *ConnectionPool) !PooledConnection {
    const conn = try pool.acquire();
    return .{
        .conn = conn,
        .pool = pool,
    };
}
