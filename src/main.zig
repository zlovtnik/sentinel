//! Process Sentinel - Main Entry Point
//! Oracle-Zig Microservice for Real-Time Process Monitoring

const std = @import("std");
const builtin = @import("builtin");

const config = @import("config/app.zig");
const ConnectionPool = @import("oracle/connection.zig").ConnectionPool;
const queue_mod = @import("oracle/queue.zig");
const QueueListener = queue_mod.QueueListener;
const SentinelEvent = queue_mod.SentinelEvent;
const WorkerPool = @import("worker/pool.zig").WorkerPool;
const ApiServer = @import("api/server.zig").ApiServer;
const metrics = @import("telemetry/metrics.zig");
const HealthChecker = @import("telemetry/health.zig").HealthChecker;

const log = std.log.scoped(.sentinel);

/// Application version - single source of truth
const VERSION = "0.1.0";

/// Application state
const AppState = struct {
    allocator: std.mem.Allocator,
    config: config.AppConfig,
    pool: ?*ConnectionPool = null,
    worker_pool: ?*WorkerPool = null,
    api_server: ?*ApiServer = null,
    queue_listener: ?*QueueListener = null,
    health_checker: ?*HealthChecker = null,
    api_thread: ?std.Thread = null,
    queue_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
};

/// Global state for signal handlers
var global_state: ?*AppState = null;

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
        .thread_safe = true,
    }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Print banner
    printBanner();

    // Load configuration
    log.info("Loading configuration...", .{});
    var app_config = config.AppConfig.init(allocator) catch |err| {
        log.err("Failed to load configuration: {any}", .{err});
        return err;
    };
    defer app_config.deinit();

    // Validate configuration
    app_config.validate() catch |err| {
        log.err("Configuration validation failed: {any}", .{err});
        return err;
    };

    log.info("Configuration loaded successfully", .{});
    log.info("HTTP Port: {d}", .{app_config.env.http_port});
    log.info("Worker Threads: {d}", .{app_config.env.worker_threads});

    // Initialize application state
    var state = AppState{
        .allocator = allocator,
        .config = app_config,
    };
    global_state = &state;
    defer global_state = null;

    // Setup signal handlers
    setupSignalHandlers();

    // Initialize components
    try initializeComponents(&state);
    defer shutdownComponents(&state);

    // Start services
    try startServices(&state);

    // Main event loop
    log.info("Process Sentinel is now running", .{});
    log.info("API endpoint: http://0.0.0.0:{d}", .{
        app_config.env.http_port,
    });

    // Wait for shutdown signal
    while (state.running.load(.monotonic)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    log.info("Shutdown signal received, gracefully shutting down...", .{});
}

fn printBanner() void {
    std.debug.print(
        \\\n        \\  ╔═══════════════════════════════════════════╗
        \\  ║       PROCESS SENTINEL v{s:<17}║
        \\  ║   Oracle-Zig Real-Time Process Monitor    ║
        \\  ╚═══════════════════════════════════════════╝
        \\
    , .{VERSION});
}

fn initializeComponents(state: *AppState) !void {
    const allocator = state.allocator;
    const cfg = &state.config;

    // Initialize metrics
    log.info("Initializing metrics...", .{});
    try metrics.initGlobalMetrics(allocator);

    // Initialize connection pool
    log.info("Initializing Oracle connection pool...", .{});
    const pool = try allocator.create(ConnectionPool);
    pool.* = try ConnectionPool.init(
        cfg.wallet,
        cfg.env.username,
        cfg.env.password,
        .{
            .min_sessions = cfg.env.pool_min_sessions,
            .max_sessions = cfg.env.pool_max_sessions,
            .session_increment = cfg.env.pool_session_increment,
            .ping_interval = cfg.env.pool_ping_interval,
            .timeout = cfg.env.pool_timeout,
            .get_mode = cfg.env.pool_get_mode,
            .wait_timeout = cfg.env.pool_wait_timeout,
            .max_lifetime_session = cfg.env.pool_max_lifetime_session,
        },
        allocator,
    );
    state.pool = pool;
    log.info("Connection pool initialized (min={d}, max={d})", .{
        cfg.env.pool_min_sessions,
        cfg.env.pool_max_sessions,
    });

    // Initialize health checker
    log.info("Initializing health checker...", .{});
    const health = try allocator.create(HealthChecker);
    health.* = HealthChecker.init(allocator, pool);
    state.health_checker = health;

    // Initialize worker pool
    log.info("Initializing worker pool...", .{});
    const workers = try allocator.create(WorkerPool);
    workers.* = try WorkerPool.init(allocator, pool, .{
        .num_workers = cfg.env.worker_threads,
        .queue_capacity = 10000,
        .task_timeout_ms = 30000,
    });
    state.worker_pool = workers;
    log.info("Worker pool initialized with {d} threads", .{cfg.env.worker_threads});

    // Initialize API server
    log.info("Initializing API server...", .{});
    const api = try allocator.create(ApiServer);
    api.* = ApiServer.init(allocator, .{
        .port = cfg.env.http_port,
        .backlog = 128,
    }, pool, null);
    state.api_server = api;

    // Initialize queue listener
    log.info("Initializing AQ listener...", .{});
    const queue = try allocator.create(QueueListener);
    queue.* = QueueListener.init(pool, cfg.env.queue_name, cfg.env.queue_event_type);
    state.queue_listener = queue;
}

fn startServices(state: *AppState) !void {
    // Start worker pool
    if (state.worker_pool) |workers| {
        log.info("Starting worker pool...", .{});
        try workers.start();
    }

    // Start API server (in background thread)
    if (state.api_server) |api| {
        log.info("Starting API server...", .{});
        state.api_thread = try std.Thread.spawn(.{}, apiServerThread, .{api});
    }

    // Start queue listener (in background thread)
    if (state.queue_listener) |queue| {
        log.info("Starting AQ listener...", .{});
        state.queue_thread = try std.Thread.spawn(.{}, queueListenerThread, .{queue});
    }
}

fn apiServerThread(api: *ApiServer) void {
    api.run() catch |err| {
        log.err("API server error: {any}", .{err});
    };
}

/// Default event handler for queue messages
fn defaultEventHandler(event: SentinelEvent, _: *std.mem.Allocator) void {
    log.info("Received event: {any}", .{event});
}

fn queueListenerThread(queue: *QueueListener) void {
    log.info("Queue listener thread started for queue: {s}", .{queue.queue_name});

    // Use a general purpose allocator for the listener
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use the public listen method which has proper error handling and backoff
    var alloc_copy = allocator;
    queue.listen(defaultEventHandler, &alloc_copy) catch |err| {
        log.err("Queue listener error: {any}", .{err});
    };

    log.info("Queue listener thread stopped", .{});
}

/// Attempt to join a thread with a bounded timeout.
/// Returns true if the thread exited within the timeout, false otherwise.
/// NOTE: Zig's std.Thread doesn't have native timed join, so this uses
/// a blocking join. The stop() methods should cause threads to exit promptly.
/// If threads hang, this will still block - consider OS-level thread
/// cancellation as a last resort in production.
/// TODO: Timeout not implemented - always returns true. When Zig adds
/// thread.tryJoin() or joinWithTimeout(), reinstate timeout handling in
/// shutdownComponents for state.queue_thread and state.api_thread.
fn joinWithTimeout(thread: std.Thread, timeout_ns: u64) bool {
    _ = timeout_ns;
    // For now, we do a blocking join since our stop() methods are designed
    // to make threads exit promptly. The timeout parameter is reserved for
    // future use when Zig supports timed joins.
    thread.join();
    return true;
}

fn shutdownComponents(state: *AppState) void {
    log.info("Shutting down components...", .{});
    const allocator = state.allocator;

    // Stop queue listener
    if (state.queue_listener) |queue| {
        queue.stop();
        log.info("Queue listener stopped", .{});
    }

    // Stop API server
    if (state.api_server) |api| {
        api.stop();
        log.info("API server stopped", .{});
    }

    // Join background threads with bounded timeout
    const join_timeout_ns: u64 = 10_000_000_000; // 10 seconds

    if (state.queue_thread) |thread| {
        _ = joinWithTimeout(thread, join_timeout_ns);
        state.queue_thread = null;
        log.info("Queue listener thread joined", .{});
    }

    if (state.api_thread) |thread| {
        _ = joinWithTimeout(thread, join_timeout_ns);
        state.api_thread = null;
        log.info("API server thread joined", .{});
    }

    // Stop worker pool
    if (state.worker_pool) |workers| {
        workers.shutdown();
        log.info("Worker pool stopped", .{});
    }

    // Cleanup connection pool
    if (state.pool) |pool| {
        pool.deinit();
        log.info("Connection pool closed", .{});
    }

    // Free allocated structs (allocated with allocator.create in initializeComponents)
    if (state.queue_listener) |queue| {
        allocator.destroy(queue);
        state.queue_listener = null;
    }
    if (state.api_server) |api| {
        allocator.destroy(api);
        state.api_server = null;
    }
    if (state.health_checker) |health| {
        allocator.destroy(health);
        state.health_checker = null;
    }
    if (state.worker_pool) |workers| {
        allocator.destroy(workers);
        state.worker_pool = null;
    }
    if (state.pool) |pool| {
        allocator.destroy(pool);
        state.pool = null;
    }

    log.info("All components shut down successfully", .{});
}

fn setupSignalHandlers() void {
    // Register SIGINT and SIGTERM handlers
    const handler = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    _ = std.posix.sigaction(std.posix.SIG.INT, &handler, null);
    _ = std.posix.sigaction(std.posix.SIG.TERM, &handler, null);

    log.info("Signal handlers registered", .{});
}

fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;
    if (global_state) |state| {
        state.running.store(false, .monotonic);
    }
}

// =============================================================================
// Public API for Testing
// =============================================================================

/// Get application version
pub fn getVersion() []const u8 {
    return VERSION;
}

/// Get build info
pub fn getBuildInfo() struct { zig_version: []const u8, target: []const u8 } {
    return .{
        .zig_version = builtin.zig_version_string,
        .target = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag),
    };
}

// =============================================================================
// Tests
// =============================================================================

test "version" {
    const version = getVersion();
    try std.testing.expect(std.mem.startsWith(u8, version, "0."));
}

test "build info" {
    const info = getBuildInfo();
    try std.testing.expect(info.zig_version.len > 0);
    try std.testing.expect(info.target.len > 0);
}
