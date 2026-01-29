//! Worker Thread Pool
//! Provides a thread pool for concurrent Oracle operations.

const std = @import("std");
const ConnectionPool = @import("../oracle/connection.zig").ConnectionPool;
const BulkLogger = @import("../oracle/bulk_insert.zig").BulkLogger;

/// Task types for worker pool
pub const TaskType = enum {
    log_batch,
    status_update,
    heartbeat_check,
    process_event,
    cleanup_expired,
    custom,
};

/// Task payload
pub const Task = struct {
    task_type: TaskType,
    payload: []const u8,
    callback: ?*const fn (TaskResult) void = null,
    priority: u8 = 5,
    created_at: i64,

    pub fn create(task_type: TaskType, payload: []const u8) Task {
        return .{
            .task_type = task_type,
            .payload = payload,
            .created_at = std.time.timestamp(),
        };
    }
};

/// Task execution result
pub const TaskResult = struct {
    success: bool,
    error_message: ?[]const u8 = null,
    duration_ns: u64 = 0,
};

/// Thread-safe task queue
pub const TaskQueue = struct {
    items: std.ArrayList(Task),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    capacity: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
        return .{
            .items = std.ArrayList(Task).init(allocator),
            .mutex = .{},
            .condition = .{},
            .capacity = capacity,
        };
    }

    /// Push a task to the queue
    pub fn push(self: *Self, task: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len >= self.capacity) {
            return error.QueueFull;
        }

        try self.items.append(task);
        self.condition.signal();
    }

    /// Pop a task from the queue (blocking with timeout)
    pub fn pop(self: *Self, timeout_ns: u64) !Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len == 0) {
            // Wait for signal with timeout
            self.condition.timedWait(&self.mutex, timeout_ns) catch {
                return error.Timeout;
            };
        }

        if (self.items.items.len == 0) {
            return error.EmptyQueue;
        }

        return self.items.orderedRemove(0);
    }

    /// Get current queue size
    pub fn size(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }

    pub fn deinit(self: *Self) void {
        self.items.deinit();
    }
};

/// Worker configuration
pub const WorkerConfig = struct {
    num_workers: usize = 4,
    queue_capacity: usize = 10000,
    task_timeout_ms: u64 = 30000,
};

/// Worker pool for concurrent task execution
pub const WorkerPool = struct {
    workers: []Worker,
    task_queue: TaskQueue,
    oracle_pool: *ConnectionPool,
    config: WorkerConfig,
    allocator: std.mem.Allocator,
    shutdown: std.atomic.Value(bool),

    // Metrics
    tasks_completed: std.atomic.Value(u64),
    tasks_failed: std.atomic.Value(u64),
    total_processing_time_ns: std.atomic.Value(u64),

    const Self = @This();

    /// Initialize worker pool
    pub fn init(
        allocator: std.mem.Allocator,
        oracle_pool: *ConnectionPool,
        config: WorkerConfig,
    ) !Self {
        const workers = try allocator.alloc(Worker, config.num_workers);

        for (workers, 0..) |*worker, i| {
            worker.* = Worker{
                .id = i,
                .thread = undefined,
                .oracle_pool = oracle_pool,
                .allocator = allocator,
            };
        }

        return .{
            .workers = workers,
            .task_queue = TaskQueue.init(allocator, config.queue_capacity),
            .oracle_pool = oracle_pool,
            .config = config,
            .allocator = allocator,
            .shutdown = std.atomic.Value(bool).init(false),
            .tasks_completed = std.atomic.Value(u64).init(0),
            .tasks_failed = std.atomic.Value(u64).init(0),
            .total_processing_time_ns = std.atomic.Value(u64).init(0),
        };
    }

    /// Start all worker threads
    pub fn start(self: *Self) !void {
        std.log.info("Starting {d} worker threads...", .{self.workers.len});

        var spawned: usize = 0;
        errdefer {
            // On error, signal shutdown and join already-spawned threads
            self.shutdown.store(true, .seq_cst);
            for (self.workers[0..spawned]) |*worker| {
                worker.thread.join();
            }
        }

        for (self.workers) |*worker| {
            worker.thread = try std.Thread.spawn(.{}, workerLoop, .{ worker, self });
            spawned += 1;
        }

        std.log.info("Worker pool started", .{});
    }

    /// Submit a task to the pool
    pub fn submit(self: *Self, task: Task) !void {
        if (self.shutdown.load(.seq_cst)) {
            return error.PoolShuttingDown;
        }
        try self.task_queue.push(task);
    }

    /// Worker loop - runs in each worker thread
    fn workerLoop(worker: *Worker, pool: *Self) void {
        std.log.debug("Worker {d} started", .{worker.id});

        // Each worker acquires its own Oracle connection
        const conn = pool.oracle_pool.acquire() catch |err| {
            std.log.err("Worker {d} failed to acquire connection: {}", .{ worker.id, err });
            return;
        };
        defer pool.oracle_pool.release(conn);

        // Convert task_timeout_ms to nanoseconds for pop timeout
        const timeout_ns = pool.config.task_timeout_ms * 1_000_000;

        while (!pool.shutdown.load(.seq_cst)) {
            // Wait for task with configured timeout
            const task = pool.task_queue.pop(timeout_ns) catch {
                continue;
            };

            const start_time = std.time.nanoTimestamp();

            // Per-task arena allocator
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const result = executeTask(task, conn, arena.allocator());

            // Clamp duration to non-negative to avoid @intCast panic
            const elapsed = std.time.nanoTimestamp() - start_time;
            const duration: u64 = if (elapsed < 0) 0 else @intCast(elapsed);
            _ = pool.total_processing_time_ns.fetchAdd(duration, .monotonic);

            if (result.success) {
                _ = pool.tasks_completed.fetchAdd(1, .monotonic);
            } else {
                _ = pool.tasks_failed.fetchAdd(1, .monotonic);
                std.log.warn("Task failed: {s}", .{result.error_message orelse "unknown"});
            }

            // Invoke callback if provided
            if (task.callback) |cb| {
                cb(result);
            }
        }

        std.log.debug("Worker {d} stopped", .{worker.id});
    }

    /// Execute a single task
    fn executeTask(task: Task, conn: anytype, allocator: std.mem.Allocator) TaskResult {
        _ = allocator;
        _ = conn;

        switch (task.task_type) {
            .log_batch => {
                // TODO: Process batch log insertion
                return .{ .success = true };
            },
            .status_update => {
                // TODO: Update process status in database
                return .{ .success = true };
            },
            .heartbeat_check => {
                // TODO: Check for stale processes
                return .{ .success = true };
            },
            .process_event => {
                // TODO: Process sentinel event
                return .{ .success = true };
            },
            .cleanup_expired => {
                // TODO: Archive old data
                return .{ .success = true };
            },
            .custom => {
                return .{ .success = true };
            },
        }
    }

    /// Get pool statistics
    pub fn getStats(self: *Self) PoolStats {
        return .{
            .queue_size = self.task_queue.size(),
            .tasks_completed = self.tasks_completed.load(.monotonic),
            .tasks_failed = self.tasks_failed.load(.monotonic),
            .total_processing_time_ns = self.total_processing_time_ns.load(.monotonic),
            .num_workers = self.workers.len,
            .is_running = !self.shutdown.load(.monotonic),
        };
    }

    /// Graceful shutdown
    pub fn shutdown(self: *Self) void {
        std.log.info("Shutting down worker pool...", .{});
        self.shutdown.store(true, .seq_cst);

        for (self.workers) |*worker| {
            worker.thread.join();
        }

        std.log.info("Worker pool shut down", .{});
    }

    pub fn deinit(self: *Self) void {
        self.task_queue.deinit();
        self.allocator.free(self.workers);
    }
};

/// Individual worker state
const Worker = struct {
    id: usize,
    thread: std.Thread,
    oracle_pool: *ConnectionPool,
    allocator: std.mem.Allocator,
};

/// Pool statistics
pub const PoolStats = struct {
    queue_size: usize,
    tasks_completed: u64,
    tasks_failed: u64,
    total_processing_time_ns: u64,
    num_workers: usize,
    is_running: bool,

    pub fn avgTaskTimeMs(self: PoolStats) f64 {
        const total = self.tasks_completed + self.tasks_failed;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.total_processing_time_ns)) / @as(f64, @floatFromInt(total)) / 1_000_000.0;
    }
};
