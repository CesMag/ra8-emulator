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
    rss: u64 = 0,
    threads: u32 = 0,
};
pub const Sample = struct {
    /// 100% is one fully occupied host CPU.
    cpu_percent: f64 = 0,
    rss: u64 = 0,
    threads: u32 = 0,
};
pub const interval_ns = 500_000_000;
pub const Sampler = struct {
    current: ?Sample = null,
    previous: ?Raw = null,
    previous_ns: u64 = 0,
    attempted_ns: ?u64 = null,

    pub fn refresh(self: *Sampler, now_ns: u64) void {
        if (self.attempted_ns) |last| if (now_ns -| last < interval_ns) return;
        self.attempted_ns = now_ns;
        const raw = platform.read() catch return;
        self.record(raw, now_ns);
    }

    /// Public so deterministic counters, reset and rollover can be tested.
    pub fn record(self: *Sampler, raw: Raw, now_ns: u64) void {
        var sample = Sample{ .rss = raw.rss, .threads = raw.threads };
        if (self.previous) |old| {
            const elapsed = now_ns -| self.previous_ns;
            if (elapsed > 0 and raw.cpu_ns >= old.cpu_ns) {
                sample.cpu_percent = @as(f64, @floatFromInt(raw.cpu_ns - old.cpu_ns)) * 100 / @as(f64, @floatFromInt(elapsed));
            }
        }
        self.previous = raw;
        self.previous_ns = now_ns;
        self.current = sample;
    }
};
