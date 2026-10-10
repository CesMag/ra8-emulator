//! Tests for src/chip/periph/clocks.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const mod = ra8.chip.periph.clocks;

const Clocks = mod.Clocks;
const Wrapped = mod.Wrapped;
const csr_countflag = mod.csr_countflag;
const csr_enable = mod.csr_enable;
const csr_tickint = mod.csr_tickint;
const demcr_trcena = mod.demcr_trcena;
const dwt_ctrl_cyccntena = mod.dwt_ctrl_cyccntena;
const icsr_pendstset = mod.icsr_pendstset;
const wrap = mod.wrap;
const observe = mod.observe;
const Observed = mod.Observed;

/// A stand-in for the PPB words this model reads and writes, so the model can
/// be tested without a CPU behind it.
const FakePpb = struct {
    words: std.AutoHashMap(u32, u32),

    fn init(allocator: std.mem.Allocator) FakePpb {
        return .{ .words = std.AutoHashMap(u32, u32).init(allocator) };
    }

    fn deinit(self: *FakePpb) void {
        self.words.deinit();
    }

    pub fn readWord(self: *FakePpb, address: u32) !u32 {
        return self.words.get(address) orelse 0;
    }

    pub fn writeWord(self: *FakePpb, address: u32, value: u32) !void {
        try self.words.put(address, value);
    }

    fn armCycleCounter(self: *FakePpb) !void {
        try self.writeWord(memmap.scb.demcr, demcr_trcena);
        try self.writeWord(memmap.dwt.ctrl, dwt_ctrl_cyccntena);
    }

    fn armSysTick(self: *FakePpb, reload: u32, csr: u32) !void {
        try self.writeWord(memmap.syst.rvr, reload);
        try self.writeWord(memmap.syst.cvr, reload);
        try self.writeWord(memmap.syst.csr, csr);
    }
};
test "the cycle counter stays where the firmware left it until it is enabled" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var clocks = Clocks{};

    try clocks.advance(&ppb, 1000);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.dwt.cyccnt));

    // The trace subsystem alone is not enough: CYCCNTENA gates it too.
    try ppb.writeWord(memmap.scb.demcr, demcr_trcena);
    try clocks.advance(&ppb, 1000);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.dwt.cyccnt));
    try std.testing.expectEqual(@as(u64, 0), clocks.cycles);
    // The run still spent the time: two advances of 1000 each.
    try std.testing.expectEqual(@as(u64, 2000), clocks.elapsed);
}

test "the run's own count moves for an image that arms no clock at all" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var clocks = Clocks{};

    // No DWT, no SysTick: the shape of every ThreadX image in this corpus.
    try clocks.advance(&ppb, 200_000);
    try std.testing.expectEqual(@as(u64, 0), clocks.cycles);
    try std.testing.expectEqual(@as(u64, 0), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 200_000), clocks.elapsed);
}

test "arming the cycle counter late leaves the two counts apart by the gap" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var clocks = Clocks{};

    try clocks.advance(&ppb, 1000);
    try ppb.armCycleCounter();
    try clocks.advance(&ppb, 1000);

    // Elapsed counts both chunks; DWT only the one it was armed for, and the
    // difference is exactly the time that passed while nothing was watching.
    try std.testing.expectEqual(@as(u64, 2000), clocks.elapsed);
    try std.testing.expectEqual(@as(u64, 1000), clocks.cycles);
}

test "an enabled cycle counter is charged the chunk it ran" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armCycleCounter();
    var clocks = Clocks{};

    try clocks.advance(&ppb, 500_000);
    try clocks.advance(&ppb, 500_000);
    try std.testing.expectEqual(@as(u32, 1_000_000), try ppb.readWord(memmap.dwt.cyccnt));
    try std.testing.expectEqual(@as(u64, 1_000_000), clocks.cycles);
    // Armed from the start, so the two agree.
    try std.testing.expectEqual(clocks.elapsed, clocks.cycles);
}

test "a firmware reset of the cycle counter is honoured and the count resumes" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armCycleCounter();
    var clocks = Clocks{};

    try clocks.advance(&ppb, 400);
    try ppb.writeWord(memmap.dwt.cyccnt, 0); // what ra8_time_init does.
    try clocks.advance(&ppb, 400);
    try std.testing.expectEqual(@as(u32, 400), try ppb.readWord(memmap.dwt.cyccnt));
}

test "a disabled SysTick does not count" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(999, 0);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 5000);
    try std.testing.expectEqual(@as(u32, 999), try ppb.readWord(memmap.syst.cvr));
    try std.testing.expectEqual(@as(u64, 0), clocks.ticks);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.syst.csr) & csr_countflag);
}

test "a chunk shorter than the counter just decrements it" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(999, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 100);
    try std.testing.expectEqual(@as(u32, 899), try ppb.readWord(memmap.syst.cvr));
    try std.testing.expectEqual(@as(u64, 0), clocks.ticks);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.syst.csr) & csr_countflag);
}

test "a wrap reloads the counter and raises COUNTFLAG" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 150);
    try std.testing.expectEqual(@as(u64, 1), clocks.ticks);
    try std.testing.expectEqual(@as(u32, 49), try ppb.readWord(memmap.syst.cvr));
    try std.testing.expect(try ppb.readWord(memmap.syst.csr) & csr_countflag != 0);
}

test "COUNTFLAG is readable for one chunk and cleared at the next boundary" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 150);
    try std.testing.expect(try ppb.readWord(memmap.syst.csr) & csr_countflag != 0);
    try clocks.advance(&ppb, 10);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.syst.csr) & csr_countflag);
    // Clearing the flag leaves the rest of SYST_CSR alone.
    try std.testing.expect(try ppb.readWord(memmap.syst.csr) & csr_enable != 0);
}

test "every period inside one chunk is counted" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 1000);
    try std.testing.expectEqual(@as(u64, 10), clocks.ticks);
}

test "a wrap pends the SysTick exception only when TICKINT is set" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 150);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.scb.icsr) & icsr_pendstset);
    try std.testing.expectEqual(@as(u64, 0), clocks.pends);

    try ppb.armSysTick(99, csr_enable | csr_tickint);
    try clocks.advance(&ppb, 150);
    try std.testing.expect(try ppb.readWord(memmap.scb.icsr) & icsr_pendstset != 0);
    try std.testing.expectEqual(@as(u64, 1), clocks.pends);
}

test "a zero reload never wraps" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(0, csr_enable | csr_tickint);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 5000);
    try std.testing.expectEqual(@as(u64, 0), clocks.ticks);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.scb.icsr) & icsr_pendstset);
}

test "the counter lands where the architecture says after a long chunk" {
    // 24-bit reload, a chunk longer than several periods: the landing value is
    // the reload minus however far past the last wrap the chunk went.
    try std.testing.expectEqual(Wrapped{ .value = 7, .periods = 0 }, wrap(10, 99, 3));
    try std.testing.expectEqual(Wrapped{ .value = 99, .periods = 1 }, wrap(10, 99, 11));
    try std.testing.expectEqual(Wrapped{ .value = 98, .periods = 1 }, wrap(10, 99, 12));
    try std.testing.expectEqual(Wrapped{ .value = 99, .periods = 2 }, wrap(10, 99, 111));
    // Zero is reached on the CVR-th tick (RA8EMU-657).
    try std.testing.expectEqual(Wrapped{ .value = 0, .periods = 1 }, wrap(10, 99, 10));
    // From a written zero the first tick only reloads; zero comes a period later.
    try std.testing.expectEqual(Wrapped{ .value = 99, .periods = 0 }, wrap(0, 99, 1));
    try std.testing.expectEqual(Wrapped{ .value = 0, .periods = 1 }, wrap(0, 99, 100));
    try std.testing.expectEqual(Wrapped{ .value = 99, .periods = 1 }, wrap(0, 99, 101));
}

test "an armed SysTick asks for a boundary one period wide" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(8_399, csr_enable | csr_tickint);
    const clocks = Clocks{};
    try std.testing.expectEqual(@as(u32, 8_400), clocks.period(&ppb));
}

test "a disabled SysTick asks for nothing" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(8_399, 0);
    const clocks = Clocks{};
    try std.testing.expectEqual(@as(u32, 0), clocks.period(&ppb));
}

test "a zero reload never wraps, so it asks for nothing" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(0, csr_enable | csr_tickint);
    const clocks = Clocks{};
    try std.testing.expectEqual(@as(u32, 0), clocks.period(&ppb));
}

test "the period a counting SysTick asks for ignores TICKINT" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(999, csr_enable);
    const clocks = Clocks{};
    try std.testing.expectEqual(@as(u32, 1_000), clocks.period(&ppb));
}

test "one boundary per period pends every period rather than collapsing them" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var collapsed = Clocks{};
    try ppb.armSysTick(999, csr_enable | csr_tickint);
    try collapsed.advance(&ppb, 6_000);
    try std.testing.expectEqual(@as(u64, 6), collapsed.ticks);
    try std.testing.expectEqual(@as(u64, 1), collapsed.pends);

    var followed = Clocks{};
    try ppb.armSysTick(999, csr_enable | csr_tickint);
    for (0..6) |_| try followed.advance(&ppb, 1_000);
    try std.testing.expectEqual(@as(u64, 6), followed.ticks);
    try std.testing.expectEqual(@as(u64, 6), followed.pends);
}

test "a stretch covering one period tells the firmware about all of it" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(999, csr_enable | csr_tickint);
    var clocks = Clocks{};

    // A period is reload + 1 ticks, so exactly one wrap.
    try clocks.advance(&ppb, 1000);
    try std.testing.expectEqual(@as(u64, 1), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 1), clocks.pends);
    try std.testing.expectEqual(@as(u64, 0), clocks.collapsed);
}

test "a stretch covering several periods raises for one and counts the rest" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable | csr_tickint);
    var clocks = Clocks{};

    // Ten periods of 100 ticks inside one stretch. COUNTFLAG and the pend
    // bit are single latches and the handler cannot run part way through, so
    // the firmware is told about one of the ten.
    try clocks.advance(&ppb, 1000);
    try std.testing.expectEqual(@as(u64, 10), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 1), clocks.pends);
    try std.testing.expectEqual(@as(u64, 9), clocks.collapsed);
}

test "the collapse is counted whether or not the firmware asked for the interrupt" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    // TICKINT clear: no pend, but COUNTFLAG is still a single bit, so a
    // firmware polling it loses the same periods.
    try ppb.armSysTick(99, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 500);
    try std.testing.expectEqual(@as(u64, 5), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 0), clocks.pends);
    try std.testing.expectEqual(@as(u64, 4), clocks.collapsed);
}

test "a stretch too short to wrap owes the firmware nothing" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(999, csr_enable | csr_tickint);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 400);
    try std.testing.expectEqual(@as(u64, 0), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 0), clocks.collapsed);
}

test "a disabled counter collapses nothing" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(9, csr_tickint);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 10_000);
    try std.testing.expectEqual(@as(u64, 0), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 0), clocks.collapsed);
}

test "the collapse accumulates across stretches" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable | csr_tickint);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 300);
    try clocks.advance(&ppb, 300);
    try std.testing.expectEqual(@as(u64, 6), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 2), clocks.pends);
    try std.testing.expectEqual(@as(u64, 4), clocks.collapsed);
}

test "one arming store ends one boundary" {
    var clock = Clocks{};
    try std.testing.expect(!clock.took());
    clock.armed();
    try std.testing.expectEqual(@as(u64, 1), clock.rearms);
    try std.testing.expect(clock.took());
    // Taken once: the latch does not end the boundary after it as well.
    try std.testing.expect(!clock.took());
    try std.testing.expectEqual(@as(u64, 1), clock.rearms);
}

test "a base on the Non-secure words counts the alias timer and leaves the normal one" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    const ns = mod.Words.non_secure;
    try std.testing.expectEqual(@as(u32, 0xE002_E010), ns.csr);
    try ppb.writeWord(ns.rvr, 99);
    try ppb.writeWord(ns.cvr, 99);
    try ppb.writeWord(ns.csr, csr_enable);
    try ppb.armSysTick(999, csr_enable);
    var clocks = Clocks{ .words = ns };

    try std.testing.expectEqual(@as(u32, 100), clocks.period(&ppb));
    try clocks.advance(&ppb, 150);
    try std.testing.expectEqual(@as(u64, 1), clocks.ticks);
    try std.testing.expect(try ppb.readWord(ns.csr) & csr_countflag != 0);
    try std.testing.expectEqual(@as(u32, 999), try ppb.readWord(memmap.syst.cvr));
    try std.testing.expectEqual(csr_enable, try ppb.readWord(memmap.syst.csr));
}
