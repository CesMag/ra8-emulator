//! The interrupt poll's shortcut (RA8EMU-318).
//!
//! `Cpu.run` asks its source what is pending before every instruction, and
//! on the board that answer costs a dozen reads of the NVIC and SCB through
//! the bus. Inside one stretch nothing can change it unless the core itself
//! touches peripheral or system space, takes an exception or returns from
//! one: the board's clocks and peripherals only move at a stretch boundary.
//! So once the source has answered "nothing pending", that answer stands
//! until one of those happens or the next stretch starts.
//!
//! Give the core `bus()` and `source()` in place of the board's own, and let
//! `Cpu.run` call `stir` as each stretch starts.
const bus_mod = @import("../bus.zig");
const Entry = @import("active.zig").Entry;
const Source = @import("source.zig").Source;

/// The first address of peripheral space. Everything below it is flash and
/// RAM, which never decides what is pending.
pub const peripheral_base: u32 = 0x4000_0000;

/// The first address of the PPB. Reading the SCB or NVIC never changes what
/// is pending, so a read from here on leaves the answer standing; the poll
/// itself reads AIRCR and SHCSR every instruction (RA8EMU-418).
pub const ppb_base: u32 = 0xE000_0000;

/// ICER and ICPR, sixteen words each, and the SCS's Non-secure alias.
const icer: u32 = 0xE000_E180;
const icpr: u32 = 0xE000_E280;
const clear_span: u32 = 0x40;
const scs_alias_offset: u32 = 0x0002_0000;

/// What a poll's decision read outside the bus. A hush holds only while
/// this is unchanged: CPSIE, MSR BASEPRI or an exception entry or return
/// the source never heard about all move it (RA8EMU-437).
pub const Key = struct {
    primask: u32,
    basepri: u32,
    faultmask: u32,
    depth: usize,
    running: u16,

    fn same(self: Key, other: Key) bool {
        return self.primask == other.primask and self.basepri == other.basepri and
            self.faultmask == other.faultmask and self.depth == other.depth and self.running == other.running;
    }
};

pub const QuietSource = struct {
    /// The source that actually knows: the NVIC model on the board.
    inner: Source,
    /// The run's own bus, which `bus()` watches.
    memory: bus_mod.Bus,
    /// The last answer was "nothing pending" and nothing has stirred since.
    settled: bool = false,
    /// The source has answered and nothing has stirred since.
    answered: bool = false,
    /// Set by `hush`: the last poll could take nothing, under `key`.
    hushed: bool = false,
    /// The hush found nothing pending at all, so it holds whatever the key.
    clear: bool = false,
    key: Key = .{ .primask = 0, .basepri = 0, .faultmask = 0, .depth = 0, .running = 0 },
    /// ICER or ICPR may hold a write the NVIC source has not folded yet:
    /// set by a store to either, a latch, or `stirAll`, and cleared by the
    /// source once it folds (NvicSource.clear_due, RA8EMU-1120).
    clear_due: bool = true,

    pub fn source(self: *QuietSource) Source {
        return .{ .ctx = self, .vtable = &.{ .winner = winner, .taken = taken, .returned = returned } };
    }

    /// The run's bus, noticing every access that could pend or unpend.
    pub fn bus(self: *QuietSource) bus_mod.Bus {
        return .{
            .ctx = self,
            .vtable = &.{ .read = read, .write = write, .latch = latch, .repeat = repeat },
            .direct = self.memory.direct,
        };
    }

    /// Forget the last answer: the next poll asks the inner source again.
    pub fn stir(self: *QuietSource) void {
        self.settled = false;
        self.answered = false;
        self.hushed = false;
    }

    /// As `stir`, for a change the core's own bus never saw (the debugger
    /// wrote state): the clear registers are folded again too.
    pub fn stirAll(self: *QuietSource) void {
        self.clear_due = true;
        self.stir();
    }

    /// The poll could take nothing: nothing pending (RA8EMU-429), or a
    /// pend that cannot preempt under `key` (RA8EMU-437). Until the next
    /// stir or a changed key it need not look again. Only an answered
    /// source hushes, so a pend found since the last stir is never held.
    pub fn hush(self: *QuietSource, key: Key, clear: bool) void {
        if (!self.answered) return;
        self.hushed = true;
        self.clear = clear;
        self.key = key;
    }

    /// True while the last hush stands for `key`. A clear hush stands for
    /// any key, so the caller may skip building it.
    pub fn holds(self: *const QuietSource, key: Key) bool {
        return self.hushed and (self.clear or self.key.same(key));
    }

    fn winner(ctx: *anyopaque, through: bus_mod.Bus) bus_mod.Error!?Entry {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        if (self.settled) return null;
        const found = try self.inner.winner(through);
        // The inner source's own reads went through `through` and stirred;
        // its answer is what settles.
        self.settled = found == null;
        self.answered = true;
        return found;
    }

    fn taken(ctx: *anyopaque, through: bus_mod.Bus, number: u9) bus_mod.Error!void {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        self.stir();
        return self.inner.taken(through, number);
    }

    fn returned(ctx: *anyopaque, through: bus_mod.Bus, number: u9) bus_mod.Error!void {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        self.stir();
        return self.inner.returned(through, number);
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus_mod.Error!void {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        if (address >= peripheral_base and address < ppb_base) self.stir();
        return self.memory.read(address, into);
    }

    /// A repeat answers as the real bus does, so a watched poll on a
    /// peripheral still retires its trips (RA8EMU-602). Repeated reads stir
    /// as the reads themselves would; asking stirs nothing.
    fn repeat(ctx: *anyopaque, address: u32, len: usize, times: u64) bool {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        if (!self.memory.repeat(address, len, times)) return false;
        if (times != 0 and address >= peripheral_base and address < ppb_base) self.stir();
        return true;
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus_mod.Error!void {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        if (address >= peripheral_base) self.stir();
        if (clearRegister(address)) self.clear_due = true;
        return self.memory.write(address, bytes);
    }

    fn latch(ctx: *anyopaque, address: u32, bits: u32) bus_mod.Error!void {
        const self: *QuietSource = @ptrCast(@alignCast(ctx));
        self.stirAll();
        return self.memory.latch(address, bits);
    }

    /// ICER or ICPR, in either copy of the SCS.
    fn clearRegister(address: u32) bool {
        const at = if (address >= ppb_base + scs_alias_offset) address - scs_alias_offset else address;
        return (at >= icer and at < icer + clear_span) or (at >= icpr and at < icpr + clear_span);
    }
};
