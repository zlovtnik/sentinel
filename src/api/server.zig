//! HTTP API Server
//! Provides REST endpoints for process status queries and control.

const std = @import("std");
const net = std.net;
const ConnectionPool = @import("../oracle/connection.zig").ConnectionPool;
const JwtValidator = @import("../security/jwt.zig").JwtValidator;

/// HTTP request parsed from raw bytes
pub const HttpRequest = struct {
    method: Method,
    path: []const u8,
    version: []const u8,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,

    pub const Method = enum {
        GET,
        POST,
        PUT,
        DELETE,
        OPTIONS,
        HEAD,
        PATCH,

        pub fn fromString(s: []const u8) ?Method {
            const map = std.StaticStringMap(Method).initComptime(.{
                .{ "GET", .GET },
                .{ "POST", .POST },
                .{ "PUT", .PUT },
                .{ "DELETE", .DELETE },
                .{ "OPTIONS", .OPTIONS },
                .{ "HEAD", .HEAD },
                .{ "PATCH", .PATCH },
            });
            return map.get(s);
        }
    };
};

/// HTTP response builder
pub const HttpResponse = struct {
    status_code: u16,
    status_text: []const u8,
    headers: std.ArrayList(Header),
    body: ?[]const u8,
    allocator: std.mem.Allocator,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) HttpResponse {
        return .{
            .status_code = 200,
            .status_text = "OK",
            .headers = std.ArrayList(Header).init(allocator),
            .body = null,
            .allocator = allocator,
        };
    }

    pub fn setStatus(self: *HttpResponse, code: u16, text: []const u8) void {
        self.status_code = code;
        self.status_text = text;
    }

    pub fn addHeader(self: *HttpResponse, name: []const u8, value: []const u8) !void {
        try self.headers.append(.{ .name = name, .value = value });
    }

    pub fn setBody(self: *HttpResponse, body: []const u8) void {
        self.body = body;
    }

    pub fn setJson(self: *HttpResponse, body: []const u8) !void {
        try self.addHeader("Content-Type", "application/json");
        self.body = body;
    }

    /// Serialize response to bytes for sending
    pub fn serialize(self: *HttpResponse) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        const writer = result.writer();

        // Status line
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{ self.status_code, self.status_text });

        // Headers
        for (self.headers.items) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }

        // Content-Length
        if (self.body) |body| {
            try writer.print("Content-Length: {d}\r\n", .{body.len});
        } else {
            try writer.print("Content-Length: 0\r\n", .{});
        }

        // End of headers
        try writer.writeAll("\r\n");

        // Body
        if (self.body) |body| {
            try writer.writeAll(body);
        }

        return result.toOwnedSlice();
    }

    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
    }
};

/// API Server configuration
pub const ServerConfig = struct {
    port: u16 = 8090,
    backlog: u31 = 128,
    max_header_size: usize = 8192,
    request_timeout_ms: u64 = 30000,
};

/// HTTP API Server
pub const ApiServer = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    pool: *ConnectionPool,
    jwt_validator: ?*JwtValidator,
    running: std.atomic.Value(bool),
    server: ?net.Server,

    // Metrics
    requests_total: std.atomic.Value(u64),
    requests_success: std.atomic.Value(u64),
    requests_error: std.atomic.Value(u64),

    const Self = @This();

    /// Initialize API server
    pub fn init(
        allocator: std.mem.Allocator,
        config: ServerConfig,
        pool: *ConnectionPool,
        jwt_validator: ?*JwtValidator,
    ) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .pool = pool,
            .jwt_validator = jwt_validator,
            .running = std.atomic.Value(bool).init(false),
            .server = null,
            .requests_total = std.atomic.Value(u64).init(0),
            .requests_success = std.atomic.Value(u64).init(0),
            .requests_error = std.atomic.Value(u64).init(0),
        };
    }

    /// Start the server (blocking)
    pub fn run(self: *Self) !void {
        const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, self.config.port);

        self.server = try address.listen(.{
            .reuse_address = true,
            .kernel_backlog = self.config.backlog,
        });

        self.running.store(true, .seq_cst);
        std.log.info("Process Sentinel API listening on port {d}", .{self.config.port});

        while (self.running.load(.seq_cst)) {
            const connection = self.server.?.accept() catch |err| {
                if (!self.running.load(.seq_cst)) break;
                std.log.err("Accept error: {}", .{err});
                continue;
            };

            // Handle connection in a new thread
            _ = std.Thread.spawn(.{}, handleConnectionWrapper, .{ self, connection }) catch |err| {
                std.log.err("Thread spawn error: {}", .{err});
                connection.stream.close();
            };
        }

        std.log.info("API server stopped", .{});
    }

    /// Wrapper for connection handling with error logging
    fn handleConnectionWrapper(self: *Self, connection: net.Server.Connection) void {
        self.handleConnection(connection);
    }

    /// Handle a single connection
    fn handleConnection(self: *Self, connection: net.Server.Connection) void {
        defer connection.stream.close();

        _ = self.requests_total.fetchAdd(1, .monotonic);

        // Per-request arena allocator
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Read and parse request
        var buf: [8192]u8 = undefined;
        const bytes_read = connection.stream.read(&buf) catch |err| {
            std.log.err("Read error: {}", .{err});
            _ = self.requests_error.fetchAdd(1, .monotonic);
            return;
        };

        if (bytes_read == 0) return;

        const request = self.parseRequest(buf[0..bytes_read], alloc) catch |err| {
            std.log.err("Parse error: {}", .{err});
            self.sendError(connection.stream, 400, "Bad Request", alloc);
            return;
        };

        // Route and handle request
        self.routeRequest(request, connection.stream, alloc) catch |err| {
            std.log.err("Handler error: {}", .{err});
            _ = self.requests_error.fetchAdd(1, .monotonic);
        };
    }

    /// Parse HTTP request from raw bytes
    fn parseRequest(self: *Self, data: []const u8, allocator: std.mem.Allocator) !HttpRequest {
        _ = self;

        var lines = std.mem.splitSequence(u8, data, "\r\n");

        // Parse request line
        const request_line = lines.first();
        var parts = std.mem.splitScalar(u8, request_line, ' ');

        const method_str = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;
        const version = parts.next() orelse return error.InvalidRequest;

        const method = HttpRequest.Method.fromString(method_str) orelse return error.InvalidMethod;

        // Parse headers
        var headers = std.StringHashMap([]const u8).init(allocator);

        while (lines.next()) |line| {
            if (line.len == 0) break; // End of headers

            const colon_idx = std.mem.indexOf(u8, line, ":") orelse continue;
            const name = std.mem.trim(u8, line[0..colon_idx], " ");
            const value = std.mem.trim(u8, line[colon_idx + 1 ..], " ");
            try headers.put(name, value);
        }

        // Body is everything after blank line
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n");
        const body = if (header_end) |idx| data[idx + 4 ..] else null;

        return .{
            .method = method,
            .path = path,
            .version = version,
            .headers = headers,
            .body = if (body != null and body.?.len > 0) body else null,
        };
    }

    /// Route request to appropriate handler
    fn routeRequest(
        self: *Self,
        request: HttpRequest,
        stream: net.Stream,
        allocator: std.mem.Allocator,
    ) !void {
        const path = request.path;

        // Health check endpoints (no auth required)
        if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/healthz")) {
            try self.handleHealth(stream, allocator);
            return;
        }

        if (std.mem.eql(u8, path, "/ready") or std.mem.eql(u8, path, "/readyz")) {
            try self.handleReady(stream, allocator);
            return;
        }

        if (std.mem.eql(u8, path, "/metrics")) {
            try self.handleMetrics(stream, allocator);
            return;
        }

        // JWT validation for protected endpoints
        if (self.jwt_validator) |validator| {
            const auth_header = request.headers.get("Authorization");
            if (auth_header == null) {
                self.sendError(stream, 401, "Unauthorized", allocator);
                return;
            }

            _ = validator.validate(auth_header.?) catch {
                self.sendError(stream, 401, "Invalid Token", allocator);
                return;
            };
        }

        // Protected endpoints
        if (std.mem.startsWith(u8, path, "/status/")) {
            const process_id = path[8..];
            try self.handleGetStatus(process_id, stream, allocator);
        } else if (std.mem.eql(u8, path, "/processes")) {
            try self.handleListProcesses(stream, allocator);
        } else if (std.mem.startsWith(u8, path, "/logs/")) {
            const process_id = path[6..];
            try self.handleGetLogs(process_id, stream, allocator);
        } else {
            self.sendError(stream, 404, "Not Found", allocator);
        }
    }

    // =========================================================================
    // Request Handlers
    // =========================================================================

    fn handleHealth(self: *Self, stream: net.Stream, allocator: std.mem.Allocator) !void {
        _ = self;
        var response = HttpResponse.init(allocator);
        defer response.deinit();

        try response.setJson("{\"status\":\"UP\"}");
        const data = try response.serialize();
        defer allocator.free(data);

        _ = try stream.write(data);
        _ = self.requests_success.fetchAdd(1, .monotonic);
    }

    fn handleReady(self: *Self, stream: net.Stream, allocator: std.mem.Allocator) !void {
        var response = HttpResponse.init(allocator);
        defer response.deinit();

        // Check Oracle connection
        const conn = self.pool.acquire() catch {
            response.setStatus(503, "Service Unavailable");
            try response.setJson("{\"status\":\"DOWN\",\"reason\":\"database\"}");
            const data = try response.serialize();
            defer allocator.free(data);
            _ = try stream.write(data);
            return;
        };
        self.pool.release(conn);

        try response.setJson("{\"status\":\"READY\"}");
        const data = try response.serialize();
        defer allocator.free(data);

        _ = try stream.write(data);
        _ = self.requests_success.fetchAdd(1, .monotonic);
    }

    fn handleMetrics(self: *Self, stream: net.Stream, allocator: std.mem.Allocator) !void {
        var response = HttpResponse.init(allocator);
        defer response.deinit();

        const pool_stats = self.pool.getStats();

        // Prometheus format
        const metrics = try std.fmt.allocPrint(allocator,
            \\# HELP sentinel_requests_total Total HTTP requests
            \\# TYPE sentinel_requests_total counter
            \\sentinel_requests_total {d}
            \\# HELP sentinel_requests_success Successful HTTP requests
            \\# TYPE sentinel_requests_success counter
            \\sentinel_requests_success {d}
            \\# HELP sentinel_requests_error Failed HTTP requests
            \\# TYPE sentinel_requests_error counter
            \\sentinel_requests_error {d}
            \\# HELP sentinel_pool_connections_open Open database connections
            \\# TYPE sentinel_pool_connections_open gauge
            \\sentinel_pool_connections_open {d}
            \\# HELP sentinel_pool_connections_busy Busy database connections
            \\# TYPE sentinel_pool_connections_busy gauge
            \\sentinel_pool_connections_busy {d}
            \\
        , .{
            self.requests_total.load(.monotonic),
            self.requests_success.load(.monotonic),
            self.requests_error.load(.monotonic),
            pool_stats.open_connections,
            pool_stats.busy_connections,
        });

        try response.addHeader("Content-Type", "text/plain; version=0.0.4");
        response.setBody(metrics);

        const data = try response.serialize();
        defer allocator.free(data);

        _ = try stream.write(data);
        _ = self.requests_success.fetchAdd(1, .monotonic);
    }

    fn handleGetStatus(
        self: *Self,
        process_id: []const u8,
        stream: net.Stream,
        allocator: std.mem.Allocator,
    ) !void {
        _ = process_id;

        var response = HttpResponse.init(allocator);
        defer response.deinit();

        // TODO: Query process_live_status table
        const json = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "process_id": "placeholder",
            \\  "status": "RUNNING",
            \\  "current_step": "PROCESSING",
            \\  "progress_percent": 50.0
            \\}}
        , .{});

        try response.setJson(json);
        const data = try response.serialize();
        defer allocator.free(data);

        _ = try stream.write(data);
        _ = self.requests_success.fetchAdd(1, .monotonic);
    }

    fn handleListProcesses(self: *Self, stream: net.Stream, allocator: std.mem.Allocator) !void {
        var response = HttpResponse.init(allocator);
        defer response.deinit();

        // TODO: Query process_registry table
        try response.setJson("{\"processes\":[]}");
        const data = try response.serialize();
        defer allocator.free(data);

        _ = try stream.write(data);
        _ = self.requests_success.fetchAdd(1, .monotonic);
    }

    fn handleGetLogs(
        self: *Self,
        process_id: []const u8,
        stream: net.Stream,
        allocator: std.mem.Allocator,
    ) !void {
        _ = process_id;

        var response = HttpResponse.init(allocator);
        defer response.deinit();

        // TODO: Query process_logs table
        try response.setJson("{\"logs\":[]}");
        const data = try response.serialize();
        defer allocator.free(data);

        _ = try stream.write(data);
        _ = self.requests_success.fetchAdd(1, .monotonic);
    }

    /// Send error response
    fn sendError(
        self: *Self,
        stream: net.Stream,
        code: u16,
        message: []const u8,
        allocator: std.mem.Allocator,
    ) void {
        var response = HttpResponse.init(allocator);
        defer response.deinit();

        response.setStatus(code, message);
        response.setJson(
            std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message}) catch return,
        ) catch return;

        const data = response.serialize() catch return;
        defer allocator.free(data);

        _ = stream.write(data) catch {};
        _ = self.requests_error.fetchAdd(1, .monotonic);
    }

    /// Stop the server
    pub fn stop(self: *Self) void {
        std.log.info("Stopping API server...", .{});
        self.running.store(false, .seq_cst);
        if (self.server) |*s| {
            s.deinit();
        }
    }

    /// Get server statistics
    pub fn getStats(self: *Self) ServerStats {
        return .{
            .requests_total = self.requests_total.load(.monotonic),
            .requests_success = self.requests_success.load(.monotonic),
            .requests_error = self.requests_error.load(.monotonic),
            .is_running = self.running.load(.monotonic),
        };
    }
};

/// Server statistics
pub const ServerStats = struct {
    requests_total: u64,
    requests_success: u64,
    requests_error: u64,
    is_running: bool,
};
