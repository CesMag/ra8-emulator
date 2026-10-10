//! Profile-selected external memory geometry, timing and usage accounting.
//! The board side of the chip's external port (RA8EMU-1041): the chip decodes
//! the apertures, and this fabric meters every access behind them.
const std = @import("std");
const initiator_mod = @import("ra8_chip").core.cpu.memory.initiator;
const port = @import("ra8_chip").core.cpu.memory.external_port;

pub const Initiator = initiator_mod.Initiator;

pub const wall_hz: u64 = 1_000_000_000;
pub const default_window_cycles: u32 = 1_000_000;

pub const Burst = enum {
    single,
    incrementing16,

    pub fn parse(text: []const u8) ?Burst {
        if (std.mem.eql(u8, text, "single")) return .single;
        if (std.mem.eql(u8, text, "incrementing16")) return .incrementing16;
        return null;
    }
};

pub const Kind = port.Kind;

pub const RegionConfig = struct {
    size: u32,
    width: u8,
    clock_hz: u32,
    latency_cycles: u8,
    burst: Burst,
};

pub const Config = struct {
    ospi: RegionConfig = .{
        .size = 256 * 1024 * 1024,
        .width = 8,
        .clock_hz = 166_666_667,
        .latency_cycles = 8,
        .burst = .incrementing16,
    },
    sdram: RegionConfig = .{
        .size = 128 * 1024 * 1024,
        .width = 32,
        .clock_hz = 133_000_000,
        .latency_cycles = 3,
        .burst = .incrementing16,
    },
    window_cycles: u32 = default_window_cycles,

    pub fn region(self: Config, kind: Kind) RegionConfig {
        return switch (kind) {
            .ospi => self.ospi,
            .sdram => self.sdram,
        };
    }

    pub fn validate(self: Config) Error!void {
        try validateRegion(.ospi, self.ospi);
        try validateRegion(.sdram, self.sdram);
        if (self.window_cycles == 0) return Error.BadWindow;
    }
};

pub const Error = error{
    BadSize,
    BadWidth,
    BadClock,
    BadLatency,
    BadWindow,
};

fn validateRegion(kind: Kind, one: RegionConfig) Error!void {
    const mib: u32 = 1024 * 1024;
    const max_size: u32 = switch (kind) {
        .ospi => 256 * mib,
        .sdram => 128 * mib,
    };
    if (one.size < mib or one.size > max_size or one.size % mib != 0 or !std.math.isPowerOfTwo(one.size / mib)) return Error.BadSize;
    const width_ok = switch (kind) {
        .ospi => one.width == 1 or one.width == 2 or one.width == 4 or one.width == 8,
        .sdram => one.width == 8 or one.width == 16 or one.width == 32,
    };
    if (!width_ok) return Error.BadWidth;
    const max_clock: u32 = switch (kind) {
        .ospi => 166_670_000,
        .sdram => 133_000_000,
    };
    if (one.clock_hz == 0 or one.clock_hz > max_clock) return Error.BadClock;
    const latency_ok = switch (kind) {
        .ospi => true,
        .sdram => one.latency_cycles >= 1 and one.latency_cycles <= 3,
    };
    if (!latency_ok) return Error.BadLatency;
}

pub const Hit = port.Hit;

pub const Layout = struct {
    config: Config,

    pub fn init(config: Config) Error!Layout {
        try config.validate();
        return .{ .config = config };
    }

    pub fn defaults() Layout {
        return .{ .config = .{} };
    }

    pub fn geometry(self: Layout) port.Geometry {
        return .{ .ospi = self.config.ospi.size, .sdram = self.config.sdram.size };
    }

    pub fn locate(self: Layout, address: u32, len: usize) ?Hit {
        return self.geometry().locate(address, len);
    }

    pub fn base(self: Layout, kind: Kind) u32 {
        _ = self;
        return kind.base();
    }

    pub fn size(self: Layout, kind: Kind) u32 {
        return self.config.region(kind).size;
    }

    /// Whether any byte of a non-empty span intersects a configured external
    /// aperture, including SDRAM's Non-secure alias.
    pub fn overlaps(self: Layout, address: u32, len: usize) bool {
        return self.geometry().overlaps(address, len);
    }
};

pub const sdram_alias_base = port.sdram_alias_base;
pub const supportedOverlap = port.supportedOverlap;

pub const Direction = port.Direction;

pub const Counters = struct {
    read_high_water_bytes: u64 = 0,
    write_high_water_bytes: u64 = 0,
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
    average_read_bytes_per_second: u64 = 0,
    average_write_bytes_per_second: u64 = 0,
    peak_read_bytes_per_second: u64 = 0,
    peak_write_bytes_per_second: u64 = 0,
    cpu_stall_cycles: u64 = 0,
    ethos_u55_stall_cycles: u64 = 0,
};

pub const Window = struct {
    index: u64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,
    peak_reads: u64 = 0,
    peak_writes: u64 = 0,
};

pub const RegionState = struct {
    available: u64 = 0,
    ready: [3]u64 = @splat(0),
    latest: u64 = 0,
    read_high: u64 = 0,
    write_high: u64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,
    stalls: [3]u64 = @splat(0),
    window: Window = .{},
};

pub const State = struct {
    config: Config,
    wall: u64,
    pending: [3]u64,
    regions: [2]RegionState,
};

pub const Fabric = struct {
    layout: Layout,
    wall: u64 = 0,
    pending: [3]u64 = @splat(0),
    regions: [2]RegionState = .{ .{}, .{} },

    pub fn init(layout: Layout) Fabric {
        return .{ .layout = layout };
    }

    pub fn state(self: *const Fabric) State {
        return .{ .config = self.layout.config, .wall = self.wall, .pending = self.pending, .regions = self.regions };
    }

    pub fn restore(self: *Fabric, saved: State) void {
        self.wall = saved.wall;
        self.pending = saved.pending;
        self.regions = saved.regions;
    }

    pub fn setWall(self: *Fabric, wall: u64) void {
        self.wall = wall;
        for (&self.regions) |*region| {
            for (&region.ready) |*ready| ready.* = @max(ready.*, wall);
        }
    }

    pub fn takePending(self: *Fabric, initiator: Initiator) u64 {
        const index = initiator.timedIndex() orelse return 0;
        const value = self.pending[index];
        self.pending[index] = 0;
        return value;
    }

    pub fn note(self: *Fabric, initiator: Initiator, hit: Hit, direction: Direction, len: usize) void {
        const initiator_index = initiator.timedIndex() orelse return;
        if (len == 0) return;
        const region_index: usize = @backingInt(hit.kind);
        const config = self.layout.config.region(hit.kind);
        const region = &self.regions[region_index];
        region.ready[initiator_index] = @max(region.ready[initiator_index], self.wall);
        var left = len;
        var offset = hit.offset;
        while (left != 0) {
            const burst_bytes: usize = if (config.burst == .single) 1 else 16;
            const bytes = @min(left, burst_bytes);
            const service = serviceCycles(config, bytes);
            const start = @max(region.ready[initiator_index], region.available);
            const end = satAdd(start, service);
            const stalled = end -| region.ready[initiator_index];
            region.ready[initiator_index] = end;
            region.available = end;
            region.latest = @max(region.latest, end);
            region.stalls[initiator_index] = satAdd(region.stalls[initiator_index], stalled);
            self.pending[initiator_index] = satAdd(self.pending[initiator_index], stalled);
            addWindow(region, self.layout.config.window_cycles, end, direction, bytes);
            left -= bytes;
            offset += @intCast(bytes);
        }
        const high = @as(u64, hit.offset) + len;
        switch (direction) {
            .read => {
                region.reads = satAdd(region.reads, len);
                region.read_high = @max(region.read_high, high);
            },
            .write => {
                region.writes = satAdd(region.writes, len);
                region.write_high = @max(region.write_high, high);
            },
        }
    }

    pub fn counters(self: *const Fabric, kind: Kind, elapsed: u64) Counters {
        const region = &self.regions[@backingInt(kind)];
        const observed = @max(elapsed, region.latest);
        const observed_window = observed / self.layout.config.window_cycles;
        const partial_width = if (observed_window > region.window.index)
            @as(u64, self.layout.config.window_cycles)
        else
            @max(@as(u64, 1), observed % self.layout.config.window_cycles + 1);
        const partial_reads = rate(region.window.reads, partial_width);
        const partial_writes = rate(region.window.writes, partial_width);
        return .{
            .read_high_water_bytes = region.read_high,
            .write_high_water_bytes = region.write_high,
            .bytes_read = region.reads,
            .bytes_written = region.writes,
            .average_read_bytes_per_second = rate(region.reads, @max(@as(u64, 1), observed)),
            .average_write_bytes_per_second = rate(region.writes, @max(@as(u64, 1), observed)),
            .peak_read_bytes_per_second = @max(region.window.peak_reads, partial_reads),
            .peak_write_bytes_per_second = @max(region.window.peak_writes, partial_writes),
            .cpu_stall_cycles = satAdd(region.stalls[0], region.stalls[1]),
            .ethos_u55_stall_cycles = region.stalls[2],
        };
    }
};

pub fn serviceCycles(config: RegionConfig, bytes: usize) u64 {
    const bits = @as(u128, bytes) * 8;
    const memory_cycles = @as(u128, config.latency_cycles) + divCeil(bits, config.width);
    const wall_cycles = divCeil(memory_cycles * wall_hz, config.clock_hz);
    return if (wall_cycles > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(wall_cycles);
}

fn addWindow(region: *RegionState, width: u32, completion: u64, direction: Direction, bytes: usize) void {
    const index = completion / width;
    if (index != region.window.index) {
        region.window.peak_reads = @max(region.window.peak_reads, rate(region.window.reads, width));
        region.window.peak_writes = @max(region.window.peak_writes, rate(region.window.writes, width));
        region.window.index = index;
        region.window.reads = 0;
        region.window.writes = 0;
    }
    switch (direction) {
        .read => region.window.reads = satAdd(region.window.reads, bytes),
        .write => region.window.writes = satAdd(region.window.writes, bytes),
    }
}

fn rate(bytes: u64, cycles: u64) u64 {
    if (cycles == 0) return 0;
    const product = @as(u128, bytes) * wall_hz;
    const value = product / cycles;
    return if (value > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(value);
}

fn divCeil(numerator: anytype, denominator: anytype) @TypeOf(numerator) {
    const d: @TypeOf(numerator) = denominator;
    return numerator / d + @intFromBool(numerator % d != 0);
}

fn satAdd(a: u64, b: anytype) u64 {
    const value = std.math.cast(u64, b) orelse return std.math.maxInt(u64);
    return a +| value;
}
