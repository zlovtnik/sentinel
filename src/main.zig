//! Process Sentinel - Main Entry Point
//! Oracle-Zig Microservice for Real-Time Process Monitoring

const std = @import("std");
const builtin = @import("builtin");

const config = @import("config/app.zig");
const ConnectionPool = @import("oracle/connection.zig").ConnectionPool;
const QueueListener = @import("oracle/queue.zig").QueueListener;
const WorkerPool = @import("worker/pool.zig").WorkerPool;
const ApiServer = @import("api/server.zig").ApiServer;
const metrics = @import("telemetry/metrics.zig");
const HealthChecker = @import("telemetry/health.zig").HealthChecker;

const log = std.log.scoped(.sentinel);

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
    var app_config = config.AppConfig.load() catch |err| {
        log.err("Failed to load configuration: {}", .{err});
        return err;
    };
    defer app_config.deinit();

    // Validate configuration
    app_config.validate() catch |err| {
        log.err("Configuration validation failed: {}", .{err});
        return err;
    };

    log.info("Configuration loaded successfully", .{});
    log.info("Service: {s}", .{app_config.sentinel.service_name});
    log.info("Instance: {s}", .{app_config.sentinel.instance_id});

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
    log.info("API endpoint: http://{s}:{d}", .{
        app_config.sentinel.listen_address,
        app_config.sentinel.listen_port,
    });

    // Wait for shutdown signal
    while (state.running.load(.monotonic)) {
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    log.info("Shutdown signal received, gracefully shutting down...", .{});
}

fn printBanner() void {
    const banner =
        \\
        \\  ╔═══════════════════════════════════════════╗
        \\  ║       PROCESS SENTINEL v0.1.0             ║
        \\  ║   Oracle-Zig Real-Time Process Monitor    ║
        \\  ╚═══════════════════════════════════════════╝
        \\
    ;
    std.debug.print("{s}\n", .{banner});
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
    pool.* = try ConnectionPool.init(allocator, .{
        .min_connections = cfg.pool.min_connections,
        .max_connections = cfg.pool.max_connections,
        .connection_timeout_ms = cfg.pool.connection_timeout_ms,
        .idle_timeout_ms = cfg.pool.idle_timeout_ms,
        .wallet_location = cfg.oracle.wallet_location,
        .wallet_password = cfg.oracle.wallet_password,
        .connect_string = cfg.oracle.connect_string,
    });
    state.pool = pool;
    log.info("Connection pool initialized (min={d}, max={d})", .{
        cfg.pool.min_connections,
        cfg.pool.max_connections,
    });

    // Initialize health checker
    log.info("Initializing health checker...", .{});
    const health = try allocator.create(HealthChecker);
    health.* = HealthChecker.init(allocator, pool);
    state.health_checker = health;

    // Initialize worker pool
    log.info("Initializing worker pool...", .{});
    const workers = try allocator.create(WorkerPool);
    workers.* = try WorkerPool.init(allocator, .{
        .thread_count = cfg.sentinel.worker_threads,
        .queue_size = 10000,
        .pool = pool,
    });
    state.worker_pool = workers;
    log.info("Worker pool initialized with {d} threads", .{cfg.sentinel.worker_threads});

    // Initialize API server
    log.info("Initializing API server...", .{});
    const api = try allocator.create(ApiServer);
    api.* = ApiServer.init(allocator, .{
        .address = cfg.sentinel.listen_address,
        .port = cfg.sentinel.listen_port,
        .pool = pool,
        .health_checker = health,
    });
    state.api_server = api;

    // Initialize queue listener
    log.info("Initializing AQ listener...", .{});
    const queue = try allocator.create(QueueListener);
    queue.* = QueueListener.init(pool, workers, cfg.sentinel.queue_name);
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
    api.start() catch |err| {
        log.err("API server error: {}", .{err});
    };
}

fn queueListenerThread(queue: *QueueListener) void {
    queue.listen() catch |err| {
        log.err("Queue listener error: {}", .{err});
    };
}

/// Attempt to join a thread with a bounded timeout.
/// Returns true if the thread exited within the timeout, false otherwise.
/// NOTE: Zig's std.Thread doesn't have native timed join, so this uses
/// a blocking join. The stop() methods should cause threads to exit promptly.
/// If threads hang, this will still block - consider OS-level thread
/// cancellation as a last resort in production.
fn joinWithTimeout(thread: std.Thread, timeout_ns: u64) bool {
    _ = timeout_ns; // TODO: Use when Zig adds thread.tryJoin() or joinWithTimeout()
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
        const joined = joinWithTimeout(thread, join_timeout_ns);
        if (joined) {
            state.queue_thread = null;
            log.info("Queue listener thread joined", .{});
        } else {
            log.err("Queue listener thread did not exit within timeout - marking as leaked", .{});
            // Thread handle leaked, but we proceed with shutdown
            state.queue_thread = null;
        }
    }

    if (state.api_thread) |thread| {
        const joined = joinWithTimeout(thread, join_timeout_ns);
        if (joined) {
            state.api_thread = null;
            log.info("API server thread joined", .{});
        } else {
            log.err("API server thread did not exit within timeout - marking as leaked", .{});
            // Thread handle leaked, but we proceed with shutdown
            state.api_thread = null;
        }
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
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &handler, null) catch {
        log.warn("Failed to setup SIGINT handler", .{});
    };
    std.posix.sigaction(std.posix.SIG.TERM, &handler, null) catch {
        log.warn("Failed to setup SIGTERM handler", .{});
    };

    log.info("Signal handlers registered", .{});
}

fn signalHandler(sig: i32) callconv(.C) void {
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
    return "0.1.0";
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
