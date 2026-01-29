//! API Route Definitions
//! Centralizes route definitions and middleware chains.

const std = @import("std");
const server = @import("server.zig");

/// Route definition
pub const Route = struct {
    method: server.HttpRequest.Method,
    path: []const u8,
    handler: Handler,
    requires_auth: bool = true,
    rate_limit: ?u32 = null,

    pub const Handler = *const fn (
        *server.HttpRequest,
        *server.HttpResponse,
        std.mem.Allocator,
    ) anyerror!void;
};

/// Route registry
pub const Routes = struct {
    routes: std.ArrayList(Route),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .routes = std.ArrayList(Route).init(allocator),
            .allocator = allocator,
        };
    }

    /// Register a route
    pub fn register(self: *Self, route: Route) !void {
        try self.routes.append(route);
    }

    /// Register a GET route
    pub fn get(self: *Self, path: []const u8, handler: Route.Handler) !void {
        try self.register(.{
            .method = .GET,
            .path = path,
            .handler = handler,
        });
    }

    /// Register a POST route
    pub fn post(self: *Self, path: []const u8, handler: Route.Handler) !void {
        try self.register(.{
            .method = .POST,
            .path = path,
            .handler = handler,
        });
    }

    /// Find matching route
    pub fn match(self: *Self, method: server.HttpRequest.Method, path: []const u8) ?Route {
        for (self.routes.items) |route| {
            if (route.method == method and self.pathMatches(route.path, path)) {
                return route;
            }
        }
        return null;
    }

    /// Check if path matches route pattern
    fn pathMatches(self: *Self, pattern: []const u8, path: []const u8) bool {
        _ = self;

        // Exact match
        if (std.mem.eql(u8, pattern, path)) return true;

        // Prefix match with parameter (e.g., "/status/" matches "/status/abc123")
        if (std.mem.endsWith(u8, pattern, "/")) {
            return std.mem.startsWith(u8, path, pattern);
        }

        // Wildcard match
        if (std.mem.endsWith(u8, pattern, "*")) {
            return std.mem.startsWith(u8, path, pattern[0 .. pattern.len - 1]);
        }

        return false;
    }

    pub fn deinit(self: *Self) void {
        self.routes.deinit();
    }
};

/// Standard API routes
pub fn registerStandardRoutes(routes: *Routes) !void {
    // Health and readiness
    try routes.register(.{
        .method = .GET,
        .path = "/health",
        .handler = undefined, // Handled directly in server
        .requires_auth = false,
    });

    try routes.register(.{
        .method = .GET,
        .path = "/ready",
        .handler = undefined,
        .requires_auth = false,
    });

    try routes.register(.{
        .method = .GET,
        .path = "/metrics",
        .handler = undefined,
        .requires_auth = false,
    });

    // Process status
    try routes.register(.{
        .method = .GET,
        .path = "/status/",
        .handler = undefined,
        .requires_auth = true,
    });

    try routes.register(.{
        .method = .GET,
        .path = "/processes",
        .handler = undefined,
        .requires_auth = true,
    });

    try routes.register(.{
        .method = .GET,
        .path = "/logs/",
        .handler = undefined,
        .requires_auth = true,
    });
}
