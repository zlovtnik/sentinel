//! Prometheus-Compatible Metrics
//! Provides metrics collection and exposition for monitoring.

const std = @import("std");

/// Metric types
pub const MetricType = enum {
    counter,
    gauge,
    histogram,
    summary,

    pub fn toString(self: MetricType) []const u8 {
        return switch (self) {
            .counter => "counter",
            .gauge => "gauge",
            .histogram => "histogram",
            .summary => "summary",
        };
    }
};

/// Label pair
pub const Label = struct {
    name: []const u8,
    value: []const u8,
};

/// Counter metric - only increases
pub const Counter = struct {
    name: []const u8,
    help: []const u8,
    value: std.atomic.Value(u64),
    labels: []const Label,

    const Self = @This();

    pub fn init(name: []const u8, help: []const u8, labels: []const Label) Self {
        return .{
            .name = name,
            .help = help,
            .value = std.atomic.Value(u64).init(0),
            .labels = labels,
        };
    }

    pub fn inc(self: *Self) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn add(self: *Self, delta: u64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    pub fn get(self: *Self) u64 {
        return self.value.load(.monotonic);
    }

    pub fn reset(self: *Self) void {
        self.value.store(0, .monotonic);
    }
};

/// Gauge metric - can go up and down
pub const Gauge = struct {
    name: []const u8,
    help: []const u8,
    value: std.atomic.Value(i64),
    labels: []const Label,

    const Self = @This();

    pub fn init(name: []const u8, help: []const u8, labels: []const Label) Self {
        return .{
            .name = name,
            .help = help,
            .value = std.atomic.Value(i64).init(0),
            .labels = labels,
        };
    }

    pub fn set(self: *Self, val: i64) void {
        self.value.store(val, .monotonic);
    }

    pub fn inc(self: *Self) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn dec(self: *Self) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    pub fn add(self: *Self, delta: i64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    pub fn get(self: *Self) i64 {
        return self.value.load(.monotonic);
    }
};

/// Histogram metric with fixed buckets
pub const Histogram = struct {
    name: []const u8,
    help: []const u8,
    buckets: []const f64,
    counts: []std.atomic.Value(u64),
    sum: std.atomic.Value(u64),
    count: std.atomic.Value(u64),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        help: []const u8,
        buckets: []const f64,
    ) !Self {
        const counts = try allocator.alloc(std.atomic.Value(u64), buckets.len + 1);
        for (counts) |*c| {
            c.* = std.atomic.Value(u64).init(0);
        }

        return .{
            .name = name,
            .help = help,
            .buckets = buckets,
            .counts = counts,
            .sum = std.atomic.Value(u64).init(0),
            .count = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    pub fn observe(self: *Self, value: f64) void {
        // Update sum and count
        const int_value: u64 = @intFromFloat(value * 1_000_000); // Store as microseconds
        _ = self.sum.fetchAdd(int_value, .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);

        // Update bucket counts
        for (self.buckets, 0..) |bucket, i| {
            if (value <= bucket) {
                _ = self.counts[i].fetchAdd(1, .monotonic);
            }
        }
        // +Inf bucket
        _ = self.counts[self.buckets.len].fetchAdd(1, .monotonic);
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.counts);
    }
};

/// Default histogram buckets for latency (seconds)
pub const DEFAULT_LATENCY_BUCKETS = [_]f64{
    0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
};

/// Metrics registry
pub const Registry = struct {
    counters: std.ArrayList(*Counter),
    gauges: std.ArrayList(*Gauge),
    histograms: std.ArrayList(*Histogram),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .counters = std.ArrayList(*Counter).init(allocator),
            .gauges = std.ArrayList(*Gauge).init(allocator),
            .histograms = std.ArrayList(*Histogram).init(allocator),
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn registerCounter(self: *Self, counter: *Counter) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.counters.append(counter);
    }

    pub fn registerGauge(self: *Self, gauge: *Gauge) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.gauges.append(gauge);
    }

    pub fn registerHistogram(self: *Self, histogram: *Histogram) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.histograms.append(histogram);
    }

    /// Export all metrics in Prometheus text format
    pub fn exportMetrics(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(u8).init(allocator);
        const writer = result.writer();

        // Export counters
        for (self.counters.items) |counter| {
            try writer.print("# HELP {s} {s}\n", .{ counter.name, counter.help });
            try writer.print("# TYPE {s} counter\n", .{counter.name});
            try self.writeLabels(writer, counter.name, counter.labels, counter.get());
        }

        // Export gauges
        for (self.gauges.items) |gauge| {
            try writer.print("# HELP {s} {s}\n", .{ gauge.name, gauge.help });
            try writer.print("# TYPE {s} gauge\n", .{gauge.name});
            try self.writeGaugeValue(writer, gauge.name, gauge.labels, gauge.get());
        }

        // Export histograms
        for (self.histograms.items) |histogram| {
            try writer.print("# HELP {s} {s}\n", .{ histogram.name, histogram.help });
            try writer.print("# TYPE {s} histogram\n", .{histogram.name});

            for (histogram.buckets, 0..) |bucket, i| {
                try writer.print("{s}_bucket{{le=\"{d}\"}} {d}\n", .{
                    histogram.name,
                    bucket,
                    histogram.counts[i].load(.monotonic),
                });
            }
            try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{
                histogram.name,
                histogram.counts[histogram.buckets.len].load(.monotonic),
            });
            try writer.print("{s}_sum {d}\n", .{ histogram.name, histogram.sum.load(.monotonic) });
            try writer.print("{s}_count {d}\n", .{ histogram.name, histogram.count.load(.monotonic) });
        }

        return result.toOwnedSlice();
    }

    fn writeLabels(
        self: *Self,
        writer: anytype,
        name: []const u8,
        labels: []const Label,
        value: u64,
    ) !void {
        _ = self;
        if (labels.len == 0) {
            try writer.print("{s} {d}\n", .{ name, value });
        } else {
            try writer.print("{s}{{", .{name});
            for (labels, 0..) |label, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{s}=\"{s}\"", .{ label.name, label.value });
            }
            try writer.print("}} {d}\n", .{value});
        }
    }

    /// Write gauge value (signed i64 - can be negative)
    fn writeGaugeValue(
        self: *Self,
        writer: anytype,
        name: []const u8,
        labels: []const Label,
        value: i64,
    ) !void {
        _ = self;
        if (labels.len == 0) {
            try writer.print("{s} {d}\n", .{ name, value });
        } else {
            try writer.print("{s}{{", .{name});
            for (labels, 0..) |label, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{s}=\"{s}\"", .{ label.name, label.value });
            }
            try writer.print("}} {d}\n", .{value});
        }
    }

    pub fn deinit(self: *Self) void {
        self.counters.deinit();
        self.gauges.deinit();
        for (self.histograms.items) |histogram| {
            histogram.deinit();
        }
        self.histograms.deinit();
    }
};

/// Pre-defined sentinel metrics
pub const SentinelMetrics = struct {
    // HTTP metrics
    http_requests_total: Counter,
    http_requests_duration: Histogram,
    http_requests_in_flight: Gauge,

    // Database metrics
    db_connections_open: Gauge,
    db_connections_busy: Gauge,
    db_queries_total: Counter,
    db_query_duration: Histogram,

    // Queue metrics
    queue_events_received: Counter,
    queue_events_processed: Counter,
    queue_events_failed: Counter,
    queue_depth: Gauge,

    // Worker metrics
    worker_tasks_total: Counter,
    worker_tasks_in_progress: Gauge,
    worker_task_duration: Histogram,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .http_requests_total = Counter.init(
                "sentinel_http_requests_total",
                "Total HTTP requests received",
                &.{},
            ),
            .http_requests_duration = try Histogram.init(
                allocator,
                "sentinel_http_request_duration_seconds",
                "HTTP request duration in seconds",
                &DEFAULT_LATENCY_BUCKETS,
            ),
            .http_requests_in_flight = Gauge.init(
                "sentinel_http_requests_in_flight",
                "Current number of HTTP requests being processed",
                &.{},
            ),
            .db_connections_open = Gauge.init(
                "sentinel_db_connections_open",
                "Number of open database connections",
                &.{},
            ),
            .db_connections_busy = Gauge.init(
                "sentinel_db_connections_busy",
                "Number of busy database connections",
                &.{},
            ),
            .db_queries_total = Counter.init(
                "sentinel_db_queries_total",
                "Total database queries executed",
                &.{},
            ),
            .db_query_duration = try Histogram.init(
                allocator,
                "sentinel_db_query_duration_seconds",
                "Database query duration in seconds",
                &DEFAULT_LATENCY_BUCKETS,
            ),
            .queue_events_received = Counter.init(
                "sentinel_queue_events_received_total",
                "Total events received from queue",
                &.{},
            ),
            .queue_events_processed = Counter.init(
                "sentinel_queue_events_processed_total",
                "Total events successfully processed",
                &.{},
            ),
            .queue_events_failed = Counter.init(
                "sentinel_queue_events_failed_total",
                "Total events that failed processing",
                &.{},
            ),
            .queue_depth = Gauge.init(
                "sentinel_queue_depth",
                "Current queue depth",
                &.{},
            ),
            .worker_tasks_total = Counter.init(
                "sentinel_worker_tasks_total",
                "Total worker tasks executed",
                &.{},
            ),
            .worker_tasks_in_progress = Gauge.init(
                "sentinel_worker_tasks_in_progress",
                "Current number of tasks being processed",
                &.{},
            ),
            .worker_task_duration = try Histogram.init(
                allocator,
                "sentinel_worker_task_duration_seconds",
                "Worker task duration in seconds",
                &DEFAULT_LATENCY_BUCKETS,
            ),
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_requests_duration.deinit();
        self.db_query_duration.deinit();
        self.worker_task_duration.deinit();
    }
};

/// Global metrics instance
pub var global_metrics: ?*SentinelMetrics = null;
var global_metrics_allocator: ?std.mem.Allocator = null;

/// Initialize global metrics
pub fn initGlobalMetrics(allocator: std.mem.Allocator) !void {
    if (global_metrics != null) {
        return; // Already initialized
    }
    const metrics = try allocator.create(SentinelMetrics);
    errdefer allocator.destroy(metrics);
    metrics.* = try SentinelMetrics.init(allocator);
    global_metrics = metrics;
    global_metrics_allocator = allocator;
}

/// Deinitialize global metrics
pub fn deinitGlobalMetrics() void {
    if (global_metrics) |metrics| {
        metrics.deinit();
        if (global_metrics_allocator) |alloc| {
            alloc.destroy(metrics);
        }
        global_metrics = null;
        global_metrics_allocator = null;
    }
}
