//! Allocation-free process health sampling (RA8EMU-1239).
pub const macos = @import("macos.zig");
pub const linux = @import("linux.zig");
const builtin = @import("builtin");
const platform = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    else => struct {
        pub fn read() !Raw {
            return error.Unsupported;
        }
    },
};
pub const Raw = struct {
    cpu_ns: u64 = 0,
    cores: u32 = 1,
    footprint: u64 = 0,
    peak_footprint: u64 = 0,
    rss: u64 = 0,
    vsz: u64 = 0,
    swap: u64 = 0,
    swap_available: bool = false,
    threads: u32 = 0,
};
pub const Sample = struct {
    /// 100% is one fully occupied host CPU; total is machine normalized.
    cpu_percent: f64 = 0,
    cpu_total_percent: f64 = 0,
    footprint: u64 = 0,
    peak_footprint: u64 = 0,
    rss: u64 = 0,
    vsz: u64 = 0,
    swap: u64 = 0,
    swap_available: bool = false,
    threads: u32 = 0,
};
pub const capacity = 120;
pub const interval_ns = 500_000_000;
pub const Sampler = struct {
    current: ?Sample = null,
    history: [capacity]Sample = @splat(.{}),
    head: usize = 0,
    count: usize = 0,
    previous: ?Raw = null,
    previous_ns: u64 = 0,
    attempted_ns: ?u64 = null,
    available: bool = false,

    pub fn refresh(self: *Sampler, now_ns: u64) void {
        if (self.attempted_ns) |last| if (now_ns -| last < interval_ns) return;
        self.attempted_ns = now_ns;
        const raw = platform.read() catch {
            self.available = false;
            return;
        };
        self.record(raw, now_ns);
    }

    /// Public so deterministic counters, reset and rollover can be tested.
    pub fn record(self: *Sampler, raw: Raw, now_ns: u64) void {
        var sample = Sample{ .footprint = raw.footprint, .peak_footprint = raw.peak_footprint, .rss = raw.rss, .vsz = raw.vsz, .swap = raw.swap, .swap_available = raw.swap_available, .threads = raw.threads };
        if (self.previous) |old| {
            const elapsed = now_ns -| self.previous_ns;
            if (elapsed > 0 and raw.cpu_ns >= old.cpu_ns) {
                sample.cpu_percent = @as(f64, @floatFromInt(raw.cpu_ns - old.cpu_ns)) * 100 / @as(f64, @floatFromInt(elapsed));
                sample.cpu_total_percent = sample.cpu_percent / @as(f64, @floatFromInt(@max(raw.cores, 1)));
            }
        }
        if (self.current) |old| sample.peak_footprint = @max(sample.peak_footprint, old.peak_footprint);
        sample.peak_footprint = @max(sample.peak_footprint, sample.footprint);
        self.previous = raw;
        self.previous_ns = now_ns;
        self.current = sample;
        self.available = true;
        self.history[self.head] = sample;
        self.head = (self.head + 1) % capacity;
        self.count = @min(self.count + 1, capacity);
    }

    pub fn at(self: *const Sampler, index: usize) Sample {
        return self.history[(self.head + capacity - self.count + index) % capacity];
    }
};
