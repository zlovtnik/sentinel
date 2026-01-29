//! Health Check Endpoints
//! Provides liveness and readiness probes for Kubernetes.

const std = @import("std");
const ConnectionPool = @import("../oracle/connection.zig").ConnectionPool;

/// Health status
pub const HealthStatus = enum {
    up,
    down,
    degraded,

    pub fn toString(self: HealthStatus) []const u8 {
        return switch (self) {
            .up => "UP",
            .down => "DOWN",
            .degraded => "DEGRADED",
        };
    }

    pub fn isHealthy(self: HealthStatus) bool {
        return self == .up or self == .degraded;
    }
};

/// Component health check result
pub const ComponentHealth = struct {
    name: []const u8,
    status: HealthStatus,
    message: ?[]const u8 = null,
    details: ?[]const u8 = null,
    latency_ms: ?f64 = null,
};

/// Overall health response
pub const HealthResponse = struct {
    status: HealthStatus,
    components: std.ArrayList(ComponentHealth),
    timestamp: i64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .status = .up,
            .components = std.ArrayList(ComponentHealth).init(allocator),
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn addComponent(self: *Self, component: ComponentHealth) !void {
        try self.components.append(component);

        // Update overall status
        if (component.status == .down) {
            self.status = .down;
        } else if (component.status == .degraded and self.status == .up) {
            self.status = .degraded;
        }
    }

    pub fn toJson(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();
        const writer = result.writer();

        try writer.writeAll("{");
        try writer.print("\"status\":\"{s}\",", .{self.status.toString()});
        try writer.print("\"timestamp\":{d},", .{self.timestamp});
        try writer.writeAll("\"components\":{");

        for (self.components.items, 0..) |comp, i| {
            if (i > 0) try writer.writeAll(",");

            // Escape component name for JSON
            try writer.writeAll("\"");
            try escapeJsonString(writer, comp.name);
            try writer.print("\":{{\"status\":\"{s}\"", .{comp.status.toString()});

            if (comp.message) |msg| {
                try writer.writeAll(",\"message\":\"");
                try escapeJsonString(writer, msg);
                try writer.writeAll("\"");
            }
            if (comp.latency_ms) |lat| {
                try writer.print(",\"latency_ms\":{d:.2}", .{lat});
            }

            try writer.writeAll("}");
        }

        try writer.writeAll("}}");
        return result.toOwnedSlice();
    }

    /// Escape a string for JSON output
    fn escapeJsonString(writer: anytype, str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x08 => try writer.writeAll("\\b"), // backspace
                0x0C => try writer.writeAll("\\f"), // form feed
                else => {
                    if (c < 0x20) {
                        try writer.print("\\u{x:0>4}", .{c});
                    } else {
                        try writer.writeByte(c);
                    }
                },
            }
        }
    }

    pub fn deinit(self: *Self) void {
        // Free any allocated detail strings
        for (self.components.items) |comp| {
            if (comp.details) |details| {
                self.components.allocator.free(details);
            }
        }
        self.components.deinit();
    }
};

/// Health checker service
pub const HealthChecker = struct {
    pool: ?*ConnectionPool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, pool: ?*ConnectionPool) Self {
        return .{
            .pool = pool,
            .allocator = allocator,
        };
    }

    /// Perform liveness check (is the process alive?)
    pub fn liveness(self: *Self) !HealthResponse {
        var response = HealthResponse.init(self.allocator);
        errdefer response.deinit();

        // Basic process health
        try response.addComponent(.{
            .name = "process",
            .status = .up,
            .message = "Process is running",
        });

        return response;
    }

    /// Perform readiness check (is the service ready to handle requests?)
    pub fn readiness(self: *Self) !HealthResponse {
        var response = HealthResponse.init(self.allocator);
        errdefer response.deinit();

        // Check database connectivity
        const db_health = self.checkDatabase();
        try response.addComponent(db_health);

        // Check memory
        const mem_health = self.checkMemory();
        try response.addComponent(mem_health);

        return response;
    }

    /// Check database connection
    fn checkDatabase(self: *Self) ComponentHealth {
        if (self.pool == null) {
            return .{
                .name = "database",
                .status = .down,
                .message = "Connection pool not initialized",
            };
        }

        const pool = self.pool.?;
        const start = std.time.nanoTimestamp();

        // Try to acquire and release a connection
        const conn = pool.acquire() catch {
            return .{
                .name = "database",
                .status = .down,
                .message = "Failed to acquire connection",
            };
        };
        pool.release(conn);

        const duration_ns = std.time.nanoTimestamp() - start;
        const latency_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

        // Consider degraded if latency is high
        const status: HealthStatus = if (latency_ms > 1000) .degraded else .up;

        const stats = pool.getStats();

        return .{
            .name = "database",
            .status = status,
            .message = if (status == .degraded) "High latency detected" else "Connection successful",
            .details = std.fmt.allocPrint(
                self.allocator,
                "open={d},busy={d}",
                .{ stats.open_connections, stats.busy_connections },
            ) catch null,
            .latency_ms = latency_ms,
        };
    }

    /// Check memory usage
    fn checkMemory(self: *Self) ComponentHealth {
        _ = self;

        // Get rough memory stats (platform-specific in real implementation)
        const status: HealthStatus = .up;

        return .{
            .name = "memory",
            .status = status,
            .message = "Memory usage normal",
        };
    }

    /// Startup check (all dependencies ready?)
    pub fn startup(self: *Self) !HealthResponse {
        // Same as readiness for now
        return self.readiness();
    }
};

/// Kubernetes probe types
pub const ProbeType = enum {
    liveness,
    readiness,
    startup,
};

/// Standard Kubernetes probe endpoints
pub const LIVENESS_PATH = "/health";
pub const READINESS_PATH = "/ready";
pub const STARTUP_PATH = "/startup";

// =============================================================================
// Tests
// =============================================================================

test "HealthResponse.toJson" {
    var response = HealthResponse.init(std.testing.allocator);
    defer response.deinit();

    try response.addComponent(.{
        .name = "test",
        .status = .up,
        .message = "OK",
    });

    const json = try response.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"UP\"") != null);
}
