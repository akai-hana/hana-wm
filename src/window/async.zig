//! Asynchronous job queue for non-blocking window manager operations.
//!
//! This module provides a priority-based job queue that allows the window manager
//! to defer expensive operations (like retiling) without blocking the event loop.
//! Jobs are executed in priority order, with sequence numbers ensuring FIFO within
//! the same priority level.

const std = @import("std");
const defs = @import("defs");
const WM = defs.WM;

pub const JobType = enum { retile, workspace_switch, layout_change };

var job_counter = std.atomic.Value(u64).init(0);

pub const Job = struct {
    id: u64,
    type: JobType,
    data: JobData,
    priority: u8 = 0,
    sequence: u64,
    cancellable: bool = true,

    pub const JobData = union(JobType) {
        retile: void,
        workspace_switch: struct { from: usize, to: usize },
        layout_change: void,
    };

    pub fn lessThan(_: void, a: Job, b: Job) std.math.Order {
        if (a.priority != b.priority) {
            return if (a.priority > b.priority) .lt else .gt;
        }
        return if (a.sequence < b.sequence) .lt else .gt;
    }
};

pub const AsyncQueue = struct {
    mutex: std.Thread.Mutex = .{},
    jobs: std.PriorityQueue(Job, void, Job.lessThan),
    pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allocator: std.mem.Allocator,
    next_job_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) !AsyncQueue {
        return .{
            .jobs = std.PriorityQueue(Job, void, Job.lessThan).init(allocator, {}),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AsyncQueue) void {
        self.jobs.deinit();
    }

    pub fn submit(self: *AsyncQueue, job_type: JobType, data: Job.JobData, priority: u8) !u64 {
        return self.submitCancellable(job_type, data, priority, true);
    }

    pub fn submitCancellable(self: *AsyncQueue, job_type: JobType, data: Job.JobData, priority: u8, cancellable: bool) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const job_id = self.next_job_id;
        self.next_job_id += 1;

        try self.jobs.add(.{
            .id = job_id,
            .type = job_type,
            .data = data,
            .priority = priority,
            .sequence = job_counter.fetchAdd(1, .monotonic),
            .cancellable = cancellable,
        });
        self.pending.store(true, .release);

        return job_id;
    }

    pub fn poll(self: *AsyncQueue) ?Job {
        if (!self.pending.load(.acquire)) return null;

        self.mutex.lock();
        defer self.mutex.unlock();

        const job = self.jobs.removeOrNull() orelse {
            self.pending.store(false, .release);
            return null;
        };

        if (self.jobs.count() == 0) {
            self.pending.store(false, .release);
        }

        return job;
    }

    /// Cancel a specific job by ID
    pub fn cancel(self: *AsyncQueue, job_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // We need to rebuild the queue without the cancelled job
        var temp_jobs = std.ArrayList(Job){};
        defer temp_jobs.deinit(self.allocator);
        temp_jobs.ensureTotalCapacity(self.allocator, self.jobs.count()) catch return false;

        var found = false;

        while (self.jobs.removeOrNull()) |job| {
            if (job.id == job_id and job.cancellable) {
                found = true;
            } else {
                temp_jobs.append(self.allocator, job) catch continue;
            }
        }

        // Re-add remaining jobs
        for (temp_jobs.items) |job| {
            self.jobs.add(job) catch {};
        }

        if (self.jobs.count() == 0) {
            self.pending.store(false, .release);
        }

        return found;
    }

    /// Cancel all jobs of a specific type
    pub fn cancelType(self: *AsyncQueue, job_type: JobType) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var temp_jobs = std.ArrayList(Job){};
        defer temp_jobs.deinit(self.allocator);
        temp_jobs.ensureTotalCapacity(self.allocator, self.jobs.count()) catch return 0;

        var cancelled: usize = 0;

        while (self.jobs.removeOrNull()) |job| {
            if (job.type == job_type and job.cancellable) {
                cancelled += 1;
            } else {
                temp_jobs.append(self.allocator, job) catch continue;
            }
        }

        // Re-add remaining jobs
        for (temp_jobs.items) |job| {
            self.jobs.add(job) catch {};
        }

        if (self.jobs.count() == 0) {
            self.pending.store(false, .release);
        }

        return cancelled;
    }

    pub inline fn hasPending(self: *AsyncQueue) bool {
        return self.pending.load(.acquire);
    }

    pub fn clear(self: *AsyncQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.jobs.removeOrNull()) |_| {}
        self.pending.store(false, .release);
    }

    /// Get the number of pending jobs
    pub fn pendingCount(self: *AsyncQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.jobs.count();
    }
};

var global_queue: ?*AsyncQueue = null;

pub fn initGlobal(allocator: std.mem.Allocator) !void {
    const queue = try allocator.create(AsyncQueue);
    errdefer allocator.destroy(queue);
    queue.* = try AsyncQueue.init(allocator);
    global_queue = queue;
}

pub fn deinitGlobal(allocator: std.mem.Allocator) void {
    if (global_queue) |queue| {
        queue.deinit();
        allocator.destroy(queue);
        global_queue = null;
    }
}

pub inline fn getGlobal() ?*AsyncQueue {
    return global_queue;
}

pub fn submitGlobal(job_type: JobType, data: Job.JobData, priority: u8) !u64 {
    if (global_queue) |queue| {
        return try queue.submit(job_type, data, priority);
    } else {
        return error.AsyncQueueNotInitialized;
    }
}

pub fn submitGlobalCancellable(job_type: JobType, data: Job.JobData, priority: u8, cancellable: bool) !u64 {
    if (global_queue) |queue| {
        return try queue.submitCancellable(job_type, data, priority, cancellable);
    } else {
        return error.AsyncQueueNotInitialized;
    }
}

pub fn cancelGlobal(job_id: u64) bool {
    if (global_queue) |queue| {
        return queue.cancel(job_id);
    }
    return false;
}

pub fn processPending(wm: *WM) void {
    const queue = global_queue orelse return;

    var processed: usize = 0;
    while (processed < defs.ASYNC_JOBS_PER_ITERATION) : (processed += 1) {
        const job = queue.poll() orelse break;

        switch (job.data) {
            .retile => @import("tiling").retileCurrentWorkspace(wm),
            .workspace_switch => |ws| @import("workspaces").switchToImmediate(wm, ws.to),
            .layout_change => @import("tiling").retileCurrentWorkspace(wm),
        }
    }
}
