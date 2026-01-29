//! Task Definitions
//! Re-exports task types and provides task builders.

const pool = @import("pool.zig");

pub const Task = pool.Task;
pub const TaskType = pool.TaskType;
pub const TaskResult = pool.TaskResult;
pub const TaskQueue = pool.TaskQueue;

/// Create a log batch task
pub fn logBatch(payload: []const u8) Task {
    return Task.create(.log_batch, payload);
}

/// Create a status update task
pub fn statusUpdate(payload: []const u8) Task {
    return Task.create(.status_update, payload);
}

/// Create a heartbeat check task
pub fn heartbeatCheck() Task {
    return Task.create(.heartbeat_check, "");
}

/// Create a process event task
pub fn processEvent(payload: []const u8) Task {
    return Task.create(.process_event, payload);
}

/// Create a cleanup task
pub fn cleanupExpired() Task {
    return Task.create(.cleanup_expired, "");
}

/// Create a custom task
pub fn custom(payload: []const u8, callback: ?*const fn (TaskResult) void) Task {
    var task = Task.create(.custom, payload);
    task.callback = callback;
    return task;
}
