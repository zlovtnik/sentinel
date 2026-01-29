//! Multi-Tenant Isolation
//! Provides tenant context and isolation enforcement.

const std = @import("std");

/// Tenant context for request processing
pub const TenantContext = struct {
    tenant_id: []const u8,
    user_id: ?[]const u8,
    roles: []const []const u8,
    is_system: bool,

    const Self = @This();

    /// Create tenant context from JWT claims
    pub fn fromClaims(
        tenant_id: []const u8,
        user_id: []const u8,
        roles: []const []const u8,
    ) Self {
        return .{
            .tenant_id = tenant_id,
            .user_id = user_id,
            .roles = roles,
            .is_system = false,
        };
    }

    /// Create system context (internal service calls)
    pub fn system() Self {
        return .{
            .tenant_id = "SYSTEM",
            .user_id = null,
            .roles = &.{},
            .is_system = true,
        };
    }

    /// Check if context has a specific role
    pub fn hasRole(self: Self, role: []const u8) bool {
        if (self.is_system) return true;
        for (self.roles) |r| {
            if (std.mem.eql(u8, r, role)) return true;
        }
        return false;
    }

    /// Check if context can access another tenant's data
    pub fn canAccessTenant(self: Self, target_tenant: []const u8) bool {
        if (self.is_system) return true;
        if (self.hasRole("admin")) return true;
        return std.mem.eql(u8, self.tenant_id, target_tenant);
    }
};

/// Thread-local tenant context storage
pub const TenantLocal = struct {
    threadlocal var current: ?TenantContext = null;

    /// Set current tenant context
    pub fn set(ctx: TenantContext) void {
        current = ctx;
    }

    /// Get current tenant context
    pub fn get() ?TenantContext {
        return current;
    }

    /// Clear current tenant context
    pub fn clear() void {
        current = null;
    }

    /// Execute function with tenant context
    pub fn withContext(ctx: TenantContext, comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
        const prev = current;
        current = ctx;
        defer current = prev;
        return @call(.auto, func, args);
    }
};

/// Find SQL keyword position respecting quotes and word boundaries
/// Returns null if keyword not found as a standalone token outside quotes
fn findKeyword(lower_sql: []const u8, keyword: []const u8) ?usize {
    var i: usize = 0;
    var in_single_quote = false;
    var in_double_quote = false;

    while (i < lower_sql.len) : (i += 1) {
        const c = lower_sql[i];

        // Handle quote state transitions
        if (c == '\'' and !in_double_quote) {
            in_single_quote = !in_single_quote;
            continue;
        }
        if (c == '"' and !in_single_quote) {
            in_double_quote = !in_double_quote;
            continue;
        }

        // Skip characters inside quotes
        if (in_single_quote or in_double_quote) continue;

        // Check for keyword match
        if (i + keyword.len <= lower_sql.len) {
            const slice = lower_sql[i .. i + keyword.len];
            if (std.mem.eql(u8, slice, keyword)) {
                // Verify word boundary before
                const valid_before = (i == 0) or !isIdentChar(lower_sql[i - 1]);
                // Verify word boundary after
                const after_pos = i + keyword.len;
                const valid_after = (after_pos >= lower_sql.len) or !isIdentChar(lower_sql[after_pos]);

                if (valid_before and valid_after) {
                    return i;
                }
            }
        }
    }
    return null;
}

/// Check if character is valid in SQL identifier
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// SQL query modifier for tenant isolation
/// Returns parameterized SQL with placeholder for tenant_id binding
pub const TenantQueryBuilder = struct {
    allocator: std.mem.Allocator,
    tenant_column: []const u8,

    const Self = @This();

    /// Result of addTenantFilter containing the modified SQL and tenant parameter.
    ///
    /// OWNERSHIP:
    /// - `sql`: Allocated buffer OWNED by the caller. The caller is responsible for
    ///   freeing this memory using the same allocator passed to TenantQueryBuilder.init().
    ///   Example: `allocator.free(result.sql);`
    /// - `tenant_param`: BORROWED slice pointing to the original tenant_id passed to
    ///   addTenantFilter. The caller must NOT free this; it remains valid only as long
    ///   as the original tenant_id slice is valid.
    pub const FilterResult = struct {
        sql: []u8,
        tenant_param: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, tenant_column: []const u8) Self {
        return .{
            .allocator = allocator,
            .tenant_column = tenant_column,
        };
    }

    /// Add tenant filter to WHERE clause
    /// Returns parameterized SQL with :tenant_id placeholder and the tenant_id value for binding
    pub fn addTenantFilter(
        self: Self,
        sql: []const u8,
        tenant_id: []const u8,
    ) !FilterResult {
        // Allocate buffer for lowercase comparison
        const lower_buf = try self.allocator.alloc(u8, sql.len);
        defer self.allocator.free(lower_buf);

        // Convert to lowercase for case-insensitive matching
        for (sql, 0..) |c, i| {
            lower_buf[i] = std.ascii.toLower(c);
        }

        // Find WHERE keyword using tokenizer that respects quotes and word boundaries
        const where_idx = findKeyword(lower_buf, "where");

        if (where_idx) |idx| {
            // Insert after WHERE with parameterized placeholder
            const before = sql[0 .. idx + 5];
            const after = sql[idx + 5 ..];
            return .{
                .sql = try std.fmt.allocPrint(
                    self.allocator,
                    "{s} {s} = :tenant_id AND {s}",
                    .{ before, self.tenant_column, after },
                ),
                .tenant_param = tenant_id,
            };
        } else {
            // Add WHERE clause before ORDER BY, GROUP BY, or at end
            // Use tokenizer for case-insensitive keyword matching
            const order_idx = findKeyword(lower_buf, "order by");
            const group_idx = findKeyword(lower_buf, "group by");

            // Pick smallest present index so WHERE is inserted before both clauses
            const insert_point = blk: {
                if (order_idx) |oi| {
                    if (group_idx) |gi| {
                        break :blk @min(oi, gi);
                    }
                    break :blk oi;
                }
                break :blk group_idx orelse sql.len;
            };
            const before = sql[0..insert_point];
            const after = sql[insert_point..];

            return .{
                .sql = try std.fmt.allocPrint(
                    self.allocator,
                    "{s} WHERE {s} = :tenant_id {s}",
                    .{ before, self.tenant_column, after },
                ),
                .tenant_param = tenant_id,
            };
        }
    }
};

/// Tenant isolation enforcement errors
pub const TenantError = error{
    TenantNotSet,
    TenantMismatch,
    AccessDenied,
    CrossTenantAccess,
};

/// Validate tenant access for a resource
pub fn validateAccess(
    ctx: TenantContext,
    resource_tenant: []const u8,
) TenantError!void {
    if (!ctx.canAccessTenant(resource_tenant)) {
        std.log.warn(
            "Tenant access denied: {s} tried to access {s}",
            .{ ctx.tenant_id, resource_tenant },
        );
        return TenantError.CrossTenantAccess;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "TenantContext.hasRole" {
    const ctx = TenantContext.fromClaims("tenant1", "user1", &.{ "viewer", "editor" });

    try std.testing.expect(ctx.hasRole("viewer"));
    try std.testing.expect(ctx.hasRole("editor"));
    try std.testing.expect(!ctx.hasRole("admin"));
}

test "TenantContext.canAccessTenant" {
    const ctx = TenantContext.fromClaims("tenant1", "user1", &.{});

    try std.testing.expect(ctx.canAccessTenant("tenant1"));
    try std.testing.expect(!ctx.canAccessTenant("tenant2"));
}

test "TenantContext.system bypasses checks" {
    const ctx = TenantContext.system();

    try std.testing.expect(ctx.hasRole("anything"));
    try std.testing.expect(ctx.canAccessTenant("any-tenant"));
}

// =============================================================================
// TenantQueryBuilder Tests
// =============================================================================

test "TenantQueryBuilder.addTenantFilter with existing WHERE clause" {
    const builder = TenantQueryBuilder.init(std.testing.allocator, "tenant_id");

    // Query with existing WHERE - tenant predicate should be appended with AND
    const result = try builder.addTenantFilter(
        "SELECT * FROM users WHERE status = 'active'",
        "tenant123",
    );
    defer std.testing.allocator.free(result.sql);

    try std.testing.expectEqualStrings("tenant123", result.tenant_param);
    try std.testing.expect(std.mem.indexOf(u8, result.sql, "WHERE tenant_id = :tenant_id AND") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.sql, "status = 'active'") != null);
}

test "TenantQueryBuilder.addTenantFilter with GROUP BY and ORDER BY" {
    const builder = TenantQueryBuilder.init(std.testing.allocator, "tenant_id");

    // Query with both GROUP BY and ORDER BY - WHERE should be inserted before both
    const result = try builder.addTenantFilter(
        "SELECT name, COUNT(*) FROM users GROUP BY name ORDER BY name",
        "tenant456",
    );
    defer std.testing.allocator.free(result.sql);

    try std.testing.expectEqualStrings("tenant456", result.tenant_param);
    // WHERE should appear before GROUP BY
    const where_pos = std.mem.indexOf(u8, result.sql, "WHERE tenant_id = :tenant_id");
    const group_pos = std.mem.indexOf(u8, result.sql, "GROUP BY");
    const order_pos = std.mem.indexOf(u8, result.sql, "ORDER BY");

    try std.testing.expect(where_pos != null);
    try std.testing.expect(group_pos != null);
    try std.testing.expect(order_pos != null);
    try std.testing.expect(where_pos.? < group_pos.?);
    try std.testing.expect(where_pos.? < order_pos.?);
}

test "TenantQueryBuilder.addTenantFilter case-insensitive keywords" {
    const builder = TenantQueryBuilder.init(std.testing.allocator, "tenant_id");

    // Mixed-case WHERE should still be recognized
    const result1 = try builder.addTenantFilter(
        "SELECT * FROM users WhErE status = 'active'",
        "tenant789",
    );
    defer std.testing.allocator.free(result1.sql);

    try std.testing.expect(std.mem.indexOf(u8, result1.sql, "tenant_id = :tenant_id AND") != null);

    // Mixed-case GROUP BY and ORDER BY
    const result2 = try builder.addTenantFilter(
        "SELECT * FROM users gRoUp By name OrDeR bY id",
        "tenantABC",
    );
    defer std.testing.allocator.free(result2.sql);

    // WHERE should be inserted before gRoUp By
    const where_pos = std.mem.indexOf(u8, result2.sql, "WHERE tenant_id = :tenant_id");
    const group_pos = std.mem.indexOf(u8, result2.sql, "gRoUp By");
    try std.testing.expect(where_pos != null);
    try std.testing.expect(group_pos != null);
    try std.testing.expect(where_pos.? < group_pos.?);
}

test "TenantQueryBuilder.addTenantFilter empty query" {
    const builder = TenantQueryBuilder.init(std.testing.allocator, "tenant_id");

    // Empty query should still get WHERE clause added
    const result = try builder.addTenantFilter("", "tenant_empty");
    defer std.testing.allocator.free(result.sql);

    try std.testing.expectEqualStrings("tenant_empty", result.tenant_param);
    try std.testing.expect(std.mem.indexOf(u8, result.sql, "WHERE tenant_id = :tenant_id") != null);
}

test "TenantQueryBuilder.addTenantFilter ORDER BY only" {
    const builder = TenantQueryBuilder.init(std.testing.allocator, "tenant_id");

    // Query with only ORDER BY - WHERE should be inserted before it
    const result = try builder.addTenantFilter(
        "SELECT * FROM users ORDER BY created_at DESC",
        "tenant_order",
    );
    defer std.testing.allocator.free(result.sql);

    const where_pos = std.mem.indexOf(u8, result.sql, "WHERE tenant_id = :tenant_id");
    const order_pos = std.mem.indexOf(u8, result.sql, "ORDER BY");

    try std.testing.expect(where_pos != null);
    try std.testing.expect(order_pos != null);
    try std.testing.expect(where_pos.? < order_pos.?);
}

test "TenantQueryBuilder.addTenantFilter GROUP BY only" {
    const builder = TenantQueryBuilder.init(std.testing.allocator, "tenant_id");

    // Query with only GROUP BY - WHERE should be inserted before it
    const result = try builder.addTenantFilter(
        "SELECT status, COUNT(*) FROM users GROUP BY status",
        "tenant_group",
    );
    defer std.testing.allocator.free(result.sql);

    const where_pos = std.mem.indexOf(u8, result.sql, "WHERE tenant_id = :tenant_id");
    const group_pos = std.mem.indexOf(u8, result.sql, "GROUP BY");

    try std.testing.expect(where_pos != null);
    try std.testing.expect(group_pos != null);
    try std.testing.expect(where_pos.? < group_pos.?);
}
