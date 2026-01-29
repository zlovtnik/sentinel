//! Arena Allocator Utilities
//! Provides per-request arena allocation patterns for zero-copy operations.

const std = @import("std");

/// Per-request arena context
pub const RequestArena = struct {
    arena: std.heap.ArenaAllocator,
    parent: std.mem.Allocator,

    const Self = @This();

    /// Create a new request arena
    pub fn init(parent: std.mem.Allocator) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent),
            .parent = parent,
        };
    }

    /// Get the arena allocator
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reset arena for reuse (keeps capacity)
    pub fn reset(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Free all memory and reset
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Allocate and copy a slice
    pub fn dupe(self: *Self, comptime T: type, slice: []const T) ![]T {
        return self.arena.allocator().dupe(T, slice);
    }

    /// Create a formatted string
    pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(self.arena.allocator(), fmt, args);
    }
};

/// Arena pool for reusing arenas across requests
pub const ArenaPool = struct {
    arenas: std.ArrayList(*RequestArena),
    available: std.ArrayList(*RequestArena),
    mutex: std.Thread.Mutex,
    parent: std.mem.Allocator,
    max_size: usize,

    const Self = @This();

    pub fn init(parent: std.mem.Allocator, max_size: usize) Self {
        return .{
            .arenas = std.ArrayList(*RequestArena).init(parent),
            .available = std.ArrayList(*RequestArena).init(parent),
            .mutex = .{},
            .parent = parent,
            .max_size = max_size,
        };
    }

    /// Acquire an arena from the pool
    pub fn acquire(self: *Self) !*RequestArena {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.popOrNull()) |arena| {
            arena.reset();
            return arena;
        }

        // Create new arena if under limit
        if (self.arenas.items.len < self.max_size) {
            const arena = try self.parent.create(RequestArena);
            arena.* = RequestArena.init(self.parent);
            self.arenas.append(arena) catch |err| {
                // Clean up on append failure
                arena.deinit();
                self.parent.destroy(arena);
                return err;
            };
            return arena;
        }

        return error.PoolExhausted;
    }

    /// Return an arena to the pool
    pub fn release(self: *Self, arena: *RequestArena) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        arena.reset();
        try self.available.append(arena);
    }

    /// Get pool statistics
    pub fn getStats(self: *Self) ArenaPoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .total = self.arenas.items.len,
            .available = self.available.items.len,
            .in_use = self.arenas.items.len - self.available.items.len,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.arenas.items) |arena| {
            arena.deinit();
            self.parent.destroy(arena);
        }
        self.arenas.deinit();
        self.available.deinit();
    }
};

pub const ArenaPoolStats = struct {
    total: usize,
    available: usize,
    in_use: usize,
};

/// Scoped arena for RAII-style cleanup
pub fn withArena(parent: std.mem.Allocator, comptime func: anytype) @typeInfo(@TypeOf(func)).Fn.return_type.? {
    var arena = RequestArena.init(parent);
    defer arena.deinit();
    return func(arena.allocator());
}

// =============================================================================
// Tests
// =============================================================================

test "RequestArena basic operations" {
    var arena = RequestArena.init(std.testing.allocator);
    defer arena.deinit();

    const str = try arena.dupe(u8, "hello");
    try std.testing.expectEqualStrings("hello", str);

    const formatted = try arena.print("value: {d}", .{42});
    try std.testing.expectEqualStrings("value: 42", formatted);
}

test "ArenaPool acquire and release" {
    var pool = ArenaPool.init(std.testing.allocator, 4);
    defer pool.deinit();

    const arena1 = try pool.acquire();
    const arena2 = try pool.acquire();

    try std.testing.expectEqual(@as(usize, 2), pool.getStats().in_use);

    pool.release(arena1);
    try std.testing.expectEqual(@as(usize, 1), pool.getStats().in_use);

    pool.release(arena2);
    try std.testing.expectEqual(@as(usize, 0), pool.getStats().in_use);
}
