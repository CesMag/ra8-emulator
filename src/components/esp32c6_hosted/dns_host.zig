//! Asynchronous host DNS resolution for the C6 station bridge. Lookups run
//! on the Worker the application hands over (RA8EMU-1020), or inline
//! without one.
const std = @import("std");
const dns = @import("dns.zig");
const eth = @import("eth.zig");
const frame = @import("frame.zig");
const Queue = @import("queue.zig").Queue;
const tape = @import("tape.zig");
const worker = @import("worker.zig");

const State = enum(u8) { running, ready };

const Job = struct {
    refs: std.atomic.Value(u8) = .init(2),
    state: std.atomic.Value(State) = .init(.running),
    canceled: std.atomic.Value(bool) = .init(false),
    valid: bool = false,
    resolver: dns.Resolver,
    route: eth.Route,
    request: [eth.udp_payload_max]u8 = undefined,
    request_len: usize,
    response: [frame.frame_size]u8 = undefined,
    answer: [eth.udp_payload_max]u8 = undefined,
    answer_len: usize = 0,

    fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.page_allocator.destroy(self);
    }
};

pub const Host = struct {
    job: ?*Job = null,
    thread: ?worker.Handle = null,
    worker: ?worker.Worker = null,

    pub fn start(self: *Host, request: []const u8, route: eth.Route, resolver: dns.Resolver, on: ?worker.Worker) void {
        if (self.job != null or request.len > eth.udp_payload_max) return;
        const job = std.heap.page_allocator.create(Job) catch return;
        job.* = .{ .resolver = resolver, .route = route, .request_len = request.len };
        @memcpy(job.request[0..request.len], request);
        self.job = job;
        const background = on orelse return run(job);
        self.thread = background.spawn(runJob, job) catch {
            self.job = null;
            std.heap.page_allocator.destroy(job);
            return;
        };
        self.worker = background;
    }

    /// Hands a finished answer to the guest; a recording run also keeps it.
    pub fn poll(self: *Host, tapes: *tape.Tape, queue: *Queue, limit: usize) void {
        const job = self.job orelse return;
        if (job.state.load(.acquire) != .ready) return;
        if (job.valid and queue.len >= limit) return;
        if (self.thread) |thread| self.worker.?.join(thread);
        self.thread = null;
        self.job = null;
        if (job.valid) _ = queue.push(&job.response);
        if (job.valid and tapes.mode == .record) tapes.storeDns(job.request[0..job.request_len], job.answer[0..job.answer_len]);
        job.release();
    }

    pub fn deinit(self: *Host) void {
        const job = self.job orelse return;
        job.canceled.store(true, .release);
        if (self.thread) |thread| self.worker.?.detach(thread);
        self.thread = null;
        self.job = null;
        job.release();
    }

    fn runJob(arg: *anyopaque) void {
        run(@ptrCast(@alignCast(arg)));
    }

    fn run(job: *Job) void {
        defer job.release();
        var payload: [eth.udp_payload_max]u8 = undefined;
        const payload_len = dns.answer(&payload, job.request[0..job.request_len], job.resolver);
        var hosted: [frame.frame_size]u8 = undefined;
        var valid = false;
        if (payload_len) |len| {
            var ethernet: [frame.max_payload]u8 = undefined;
            if (eth.udpFrame(&ethernet, job.route, payload[0..len])) |ethernet_len| {
                valid = true;
                frame.build(&hosted, .{ .interface = .sta, .if_num = 0 }, ethernet[0..ethernet_len]) catch {
                    valid = false;
                };
            }
        }
        if (!job.canceled.load(.acquire)) {
            if (valid) job.response = hosted;
            if (valid) job.answer_len = payload_len.?;
            if (valid) @memcpy(job.answer[0..job.answer_len], payload[0..job.answer_len]);
            job.valid = valid;
        }
        job.state.store(.ready, .release);
    }
};
