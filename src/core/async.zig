//! Asynchronous job queue for non-blocking window manager operations.

const std = @import("std");
const defs = @import("defs");
const WM = defs.WM;

pub const JobType = enum { retile, workspace_switch, layout_change };

var job_counter = std.atomic.Value(u64).init(0);

pub const Job = struct {
    type: JobType,
    data: JobData,
    priority: u8 = 0,
    sequence: u64,

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

    pub fn init(allocator: std.mem.Allocator) !AsyncQueue {
        return .{
            .jobs = std.PriorityQueue(Job, void, Job.lessThan).init(allocator, {}),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AsyncQueue) void {
        self.jobs.deinit();
    }

    pub fn submit(self: *AsyncQueue, job_type: JobType, data: Job.JobData, priority: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.jobs.add(.{
            .type = job_type,
            .data = data,
            .priority = priority,
            .sequence = job_counter.fetchAdd(1, .monotonic),
        });
        self.pending.store(true, .release);
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

    pub inline fn hasPending(self: *AsyncQueue) bool {
        return self.pending.load(.acquire);
    }

    pub fn clear(self: *AsyncQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.jobs.removeOrNull()) |_| {}
        self.pending.store(false, .release);
    }
};

var global_queue: ?*AsyncQueue = null;

pub fn initGlobal(allocator: std.mem.Allocator) !void {
    const queue = try allocator.create(AsyncQueue);
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

pub fn submitGlobal(job_type: JobType, data: Job.JobData, priority: u8) !void {
    if (global_queue) |queue| try queue.submit(job_type, data, priority);
}

pub fn processPending(wm: *WM) void {
    const queue = global_queue orelse return;

    var processed: usize = 0;
    while (processed < 5) : (processed += 1) {
        const job = queue.poll() orelse break;

        switch (job.data) {
            .retile => @import("tiling").retileCurrentWorkspace(wm),
            .workspace_switch => |ws| @import("workspaces").switchToImmediate(wm, ws.to),
            .layout_change => @import("tiling").retileCurrentWorkspace(wm),
        }
    }
}
