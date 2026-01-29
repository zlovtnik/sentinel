//! OpenTelemetry Tracing
//! Provides distributed tracing support.

const std = @import("std");

/// Trace ID (128-bit)
pub const TraceId = struct {
    high: u64,
    low: u64,

    pub fn generate() TraceId {
        return .{
            .high = std.crypto.random.int(u64),
            .low = std.crypto.random.int(u64),
        };
    }

    pub fn toHex(self: TraceId) [32]u8 {
        var buf: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{x:0>16}{x:0>16}", .{ self.high, self.low }) catch unreachable;
        return buf;
    }

    pub fn fromHex(hex: []const u8) !TraceId {
        if (hex.len != 32) return error.InvalidTraceId;
        return .{
            .high = try std.fmt.parseInt(u64, hex[0..16], 16),
            .low = try std.fmt.parseInt(u64, hex[16..32], 16),
        };
    }
};

/// Span ID (64-bit)
pub const SpanId = struct {
    value: u64,

    pub fn generate() SpanId {
        return .{ .value = std.crypto.random.int(u64) };
    }

    pub fn toHex(self: SpanId) [16]u8 {
        var buf: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{x:0>16}", .{self.value}) catch unreachable;
        return buf;
    }

    pub fn fromHex(hex: []const u8) !SpanId {
        if (hex.len != 16) return error.InvalidSpanId;
        return .{
            .value = try std.fmt.parseInt(u64, hex, 16),
        };
    }
};

/// Span status
pub const SpanStatus = enum {
    unset,
    ok,
    @"error",
};

/// Span kind
pub const SpanKind = enum {
    internal,
    server,
    client,
    producer,
    consumer,
};

/// Span attribute
pub const Attribute = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        float: f64,
        bool: bool,
    };
};

/// Span event
pub const SpanEvent = struct {
    name: []const u8,
    timestamp: i128,
    attributes: []const Attribute,
};

/// Span represents a single operation in a trace
pub const Span = struct {
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: ?SpanId,
    name: []const u8,
    kind: SpanKind,
    start_time: i128,
    end_time: ?i128,
    status: SpanStatus,
    status_message: ?[]const u8,
    attributes: std.ArrayList(Attribute),
    events: std.ArrayList(SpanEvent),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        kind: SpanKind,
        parent: ?*Span,
    ) Self {
        return .{
            .trace_id = if (parent) |p| p.trace_id else TraceId.generate(),
            .span_id = SpanId.generate(),
            .parent_span_id = if (parent) |p| p.span_id else null,
            .name = name,
            .kind = kind,
            .start_time = std.time.nanoTimestamp(),
            .end_time = null,
            .status = .unset,
            .status_message = null,
            .attributes = std.ArrayList(Attribute).init(allocator),
            .events = std.ArrayList(SpanEvent).init(allocator),
            .allocator = allocator,
        };
    }

    /// Add an attribute to the span
    pub fn setAttribute(self: *Self, key: []const u8, value: Attribute.Value) !void {
        try self.attributes.append(.{ .key = key, .value = value });
    }

    /// Add an event to the span
    pub fn addEvent(self: *Self, name: []const u8, attributes: []const Attribute) !void {
        try self.events.append(.{
            .name = name,
            .timestamp = std.time.nanoTimestamp(),
            .attributes = attributes,
        });
    }

    /// Set span status
    pub fn setStatus(self: *Self, status: SpanStatus, message: ?[]const u8) void {
        self.status = status;
        self.status_message = message;
    }

    /// End the span
    pub fn end(self: *Self) void {
        self.end_time = std.time.nanoTimestamp();
    }

    /// Get duration in nanoseconds
    pub fn getDurationNs(self: *Self) ?i128 {
        if (self.end_time) |end_val| {
            return end_val - self.start_time;
        }
        return null;
    }

    pub fn deinit(self: *Self) void {
        self.attributes.deinit();
        self.events.deinit();
    }
};

/// Tracer for creating spans
pub const Tracer = struct {
    name: []const u8,
    version: []const u8,
    exporter: ?*SpanExporter,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
        exporter: ?*SpanExporter,
    ) Self {
        return .{
            .name = name,
            .version = version,
            .exporter = exporter,
            .allocator = allocator,
        };
    }

    /// Start a new span
    pub fn startSpan(self: *Self, name: []const u8, kind: SpanKind, parent: ?*Span) Span {
        return Span.init(self.allocator, name, kind, parent);
    }

    /// End and export a span
    pub fn endSpan(self: *Self, span: *Span) void {
        span.end();
        if (self.exporter) |exp| {
            exp.exportSpan(span) catch |err| {
                std.log.err("Failed to export span: {any}", .{err});
            };
        }
    }
};

/// Span exporter interface
pub const SpanExporter = struct {
    exportFn: *const fn (*SpanExporter, *Span) anyerror!void,

    pub fn exportSpan(self: *SpanExporter, span: *Span) !void {
        return self.exportFn(self, span);
    }
};

/// Console span exporter (for development)
pub const ConsoleExporter = struct {
    exporter: SpanExporter,

    const Self = @This();

    pub fn init() Self {
        return .{
            .exporter = .{
                .exportFn = exportImpl,
            },
        };
    }

    fn exportImpl(exporter: *SpanExporter, span: *Span) !void {
        _ = exporter;
        const duration_ns = span.getDurationNs() orelse 0;
        const duration_ms = @as(f64, @floatFromInt(@as(i64, @intCast(@min(duration_ns, std.math.maxInt(i64)))))) / 1_000_000.0;

        std.log.info(
            "SPAN: {s} [trace={s}, span={s}, duration={d:.2}ms]",
            .{
                span.name,
                &span.trace_id.toHex(),
                &span.span_id.toHex(),
                duration_ms,
            },
        );
    }
};

/// Trace context for propagation
pub const TraceContext = struct {
    trace_id: TraceId,
    span_id: SpanId,
    trace_flags: u8,
    trace_state: ?[]const u8,

    const Self = @This();

    /// Parse W3C traceparent header
    pub fn fromTraceparent(header: []const u8) !Self {
        // Format: version-trace_id-span_id-flags
        // Example: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
        var parts = std.mem.splitScalar(u8, header, '-');

        const version = parts.next() orelse return error.InvalidTraceparent;
        // W3C spec: Accept unknown versions (forward compatibility)
        // Only reject version "ff" which is explicitly invalid
        if (std.mem.eql(u8, version, "ff")) return error.InvalidVersion;
        // Validate version is 2 hex characters
        if (version.len != 2) return error.InvalidTraceparent;
        _ = std.fmt.parseInt(u8, version, 16) catch return error.InvalidTraceparent;

        const trace_id_hex = parts.next() orelse return error.InvalidTraceparent;
        const span_id_hex = parts.next() orelse return error.InvalidTraceparent;
        const flags_hex = parts.next() orelse return error.InvalidTraceparent;

        return .{
            .trace_id = try TraceId.fromHex(trace_id_hex),
            .span_id = try SpanId.fromHex(span_id_hex),
            .trace_flags = try std.fmt.parseInt(u8, flags_hex, 16),
            .trace_state = null,
        };
    }

    /// Generate traceparent header
    pub fn toTraceparent(self: Self, buf: []u8) ![]u8 {
        return try std.fmt.bufPrint(buf, "00-{s}-{s}-{x:0>2}", .{
            &self.trace_id.toHex(),
            &self.span_id.toHex(),
            self.trace_flags,
        });
    }
};

// =============================================================================
// Tests
// =============================================================================

test "TraceId generation and conversion" {
    const id = TraceId.generate();
    const hex = id.toHex();
    const parsed = try TraceId.fromHex(&hex);

    try std.testing.expectEqual(id.high, parsed.high);
    try std.testing.expectEqual(id.low, parsed.low);
}

test "SpanId generation and conversion" {
    const id = SpanId.generate();
    const hex = id.toHex();
    const parsed = try SpanId.fromHex(&hex);

    try std.testing.expectEqual(id.value, parsed.value);
}
