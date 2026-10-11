//! Call-stack samples tagged with their core, thread and virtual time, and
//! their fold into flame-graph rows over a window (RA8EMU-831, RA8EMU-952).
//!
//! The store keeps addresses only. Naming a frame is the caller's, through
//! `Names`, so nothing here knows the ELF. A fold writes `outer;...;inner n`
//! rows, merging identical stacks and sorting them on their addresses from
//! the outermost frame in, so the same samples always fold to the same bytes
//! whatever order they arrived in.
const std = @import("std");

pub const limits = struct {
    pub const depth: usize = 32;
    pub const samples: usize = 2048;
};

pub const Sample = struct {
    core: u8,
    /// The RTOS thread running when it was taken; 0 with no RTOS.
    thread: u32,
    at_ns: u64,
    len: u8,
    /// Innermost first, as an unwinder walks them.
    frames: [limits.depth]u32,

    pub fn stack(self: *const Sample) []const u32 {
        return self.frames[0..self.len];
    }
};

/// The oldest samples go first when it fills, and are counted.
pub const Store = struct {
    samples: [limits.samples]Sample = undefined,
    oldest: usize = 0,
    count: usize = 0,
    dropped: u64 = 0,

    /// Keep one sample; frames past `limits.depth` (the outermost) are cut.
    pub fn push(self: *Store, core: u8, thread: u32, at_ns: u64, stack: []const u32) void {
        const len = @min(stack.len, limits.depth);
        var slot: usize = undefined;
        if (self.count == limits.samples) {
            slot = self.oldest;
            self.oldest = (self.oldest + 1) % limits.samples;
            self.dropped += 1;
        } else {
            slot = (self.oldest + self.count) % limits.samples;
            self.count += 1;
        }
        const sample = &self.samples[slot];
        sample.* = .{ .core = core, .thread = thread, .at_ns = at_ns, .len = @intCast(len), .frames = undefined };
        @memcpy(sample.frames[0..len], stack[0..len]);
    }

    /// The `index`th oldest sample kept.
    pub fn at(self: *const Store, index: usize) *const Sample {
        return &self.samples[(self.oldest + index) % limits.samples];
    }
};

/// Which samples a fold takes: one core, a window [from_ns, to_ns), and
/// one thread or all of them.
pub const Filter = struct {
    core: u8,
    from_ns: u64 = 0,
    to_ns: u64 = std.math.maxInt(u64),
    thread: ?u32 = null,

    pub fn takes(self: Filter, sample: *const Sample) bool {
        if (sample.core != self.core) return false;
        if (sample.at_ns < self.from_ns or sample.at_ns >= self.to_ns) return false;
        if (self.thread) |thread| return sample.thread == thread;
        return true;
    }
};

/// A frame's name, or null to print its address.
pub const Names = struct {
    context: *const anyopaque,
    nameFn: *const fn (context: *const anyopaque, address: u32) ?[]const u8,

    pub fn name(self: Names, address: u32) ?[]const u8 {
        return self.nameFn(self.context, address);
    }
};

/// Write the fold of the samples `filter` takes. `scratch` needs room for
/// every sample kept; it holds their indices while they are sorted.
pub fn fold(store: *const Store, filter: Filter, names: Names, out: anytype, scratch: []usize) !void {
    std.debug.assert(scratch.len >= store.count);
    var taken: usize = 0;
    for (0..store.count) |index| {
        if (!filter.takes(store.at(index))) continue;
        scratch[taken] = index;
        taken += 1;
    }
    const picked = scratch[0..taken];
    std.mem.sort(usize, picked, store, before);
    var run: usize = 0;
    while (run < picked.len) {
        const stack = store.at(picked[run]).stack();
        var next = run + 1;
        while (next < picked.len and std.mem.eql(u32, store.at(picked[next]).stack(), stack)) next += 1;
        try row(out, names, stack, next - run);
        run = next;
    }
}

fn before(store: *const Store, lhs: usize, rhs: usize) bool {
    return order(store.at(lhs).stack(), store.at(rhs).stack()) == .lt;
}

/// Compare two stacks from the outermost frame in; a stack that is a prefix
/// of another, seen from the outside, comes first.
pub fn order(lhs: []const u32, rhs: []const u32) std.math.Order {
    const shared = @min(lhs.len, rhs.len);
    for (0..shared) |depth| {
        const a = lhs[lhs.len - 1 - depth];
        const b = rhs[rhs.len - 1 - depth];
        if (a != b) return std.math.order(a, b);
    }
    return std.math.order(lhs.len, rhs.len);
}

fn row(out: anytype, names: Names, stack: []const u32, count: usize) !void {
    var depth = stack.len;
    while (depth > 0) {
        depth -= 1;
        try frame(out, names, stack[depth]);
        if (depth != 0) try out.writeAll(";");
    }
    try out.print(" {d}\n", .{count});
}

fn frame(out: anytype, names: Names, address: u32) !void {
    if (names.name(address)) |found| return out.writeAll(found);
    try out.print("0x{x:0>8}", .{address});
}
