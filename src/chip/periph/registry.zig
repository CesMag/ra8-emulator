//! The peripheral window and the blocks that live in it.
//!
//! The RA8D2 puts every Renesas peripheral in one window at 0x40000000, with a
//! Non-secure alias 0x10000000 above it. Firmware reaches that window long
//! before it reaches anything interesting, so the bus has to answer every
//! access: a modelled block answers for its own range, and everything else
//! falls through to a sparse register file that remembers what was written.
//!
//! The sparse fallback is not laziness, it is what lets unported firmware get
//! anywhere. A driver writes a control register and reads it back to check the
//! write took, so reads return the last value written. A driver then spins on a
//! status bit waiting for "ready", and a register nothing models would spin
//! forever, so an address read repeatedly with nothing written to it alternates
//! between zero and all-ones: a poll for either polarity of a single bit falls
//! through instead of hanging.
const std = @import("std");

/// The Secure peripheral window. These are silicon facts, not options.
pub const base: u32 = 0x4000_0000;
pub const size: u32 = 0x1000_0000;
/// The IDAU bit[28] Non-secure alias of the same window.
pub const ns_offset: u32 = 0x1000_0000;
pub const ns_base: u32 = base + ns_offset;

pub const Access = enum { read, write };

/// The core an access came from. The bus is one block list both cores
/// reach, but a few RA8 blocks (the per-core ICU above all) answer the core
/// in front of them, so each core goes on the bus through its own Port and
/// the bus remembers whose access it is serving.
pub const Issuer = enum { cpu0, cpu1 };

/// One core's way onto the bus: what an engine's MMIO hook is handed.
pub const Port = struct {
    bus: *Bus,
    issuer: Issuer,

    pub fn read(self: *Port, address: u32, width: u3) u32 {
        self.bus.issuer = self.issuer;
        return self.bus.read(address, width);
    }

    pub fn write(self: *Port, address: u32, width: u3, value: u32) void {
        self.bus.issuer = self.issuer;
        self.bus.write(address, width, value);
    }
};

/// A veto over the whole window, consulted before anything answers. The
/// module-stop gate in src/chip/periph/mstp/mstp.zig is the one that exists: a
/// peripheral whose module-stop bit is set is unclocked, so it does not answer
/// the bus at all.
pub const Gate = struct {
    context: *anyopaque,
    stoppedFn: *const fn (context: *anyopaque, address: u32) bool,
    noteFn: *const fn (context: *anyopaque, address: u32, access: Access) void,

    fn drops(self: Gate, address: u32, access: Access) bool {
        if (!self.stoppedFn(self.context, address)) return false;
        self.noteFn(self.context, address, access);
        return true;
    }
};

/// A modelled peripheral block: an absolute register range and the two
/// handlers that answer for it. A block owns its own state; the bus only
/// routes.
pub const Block = struct {
    name: []const u8,
    base: u32,
    size: u32,
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, address: u32, width: u3) u32,
    writeFn: *const fn (context: *anyopaque, address: u32, width: u3, value: u32) void,
    /// Counts `times` more reads that answer as the last did; false when
    /// the register cannot promise that. Null repeats nothing (RA8EMU-595).
    repeatFn: ?*const fn (context: *anyopaque, address: u32, width: u3, times: u64) bool = null,
    /// The stored value with none of a read's side effects, for a report
    /// looking at a register after the run. Null leaves it unreadable
    /// rather than risk a clear-on-read or a FIFO pop (RA8EMU-631).
    peekFn: ?*const fn (context: *anyopaque, address: u32, width: u3) u32 = null,

    pub fn end(self: Block) u64 {
        return @as(u64, self.base) + self.size;
    }

    pub fn covers(self: Block, address: u32) bool {
        return address >= self.base and address < self.end();
    }
};

pub const Error = error{
    TooManyBlocks,
    OverlappingBlock,
    OutsideWindow,
};

/// One sparse register: the last value written, and how many times it has been
/// read with nothing ever written to it.
const Cell = struct {
    value: u32 = 0,
    written: bool = false,
    reads: u32 = 0,
};

pub const Counters = struct {
    reads: u64 = 0,
    writes: u64 = 0,
    modelled: u64 = 0,
};

/// How many modelled blocks the bus holds. It was 64 and exactly 64 were
/// attached, so the next block of any kind failed attach with
/// TooManyBlocks. A peripheral whose registers sit in two or three separate
/// runs needs an entry per run, so the ceiling has to lead the tree rather
/// than sit flush against it. 96 filled the same way once the CPSCU SRAM
/// attribution windows arrived (RA8EMU-230).
pub const max_blocks = 192;

/// The peripheral bus: a small registry of modelled blocks plus the sparse
/// register file behind them.
pub const Bus = struct {
    blocks: [max_blocks]Block = undefined,
    count: usize = 0,
    cells: std.AutoHashMap(u32, Cell),
    counters: Counters = .{},
    /// Set once the module-stop model is attached; null leaves every address
    /// clocked, which is what the smaller tests and the loader want.
    gate: ?Gate = null,
    /// Whether the access being served came through the Non-secure alias.
    /// The fold below hands every block the Secure address, so a block whose
    /// answer depends on the alias (MSTP, RA8EMU-354) reads it here.
    nonsecure: bool = false,
    /// Whose access is being served. Set by the Port the access came
    /// through; CPU0 when nothing has said otherwise.
    issuer: Issuer = .cpu0,
    ports: [2]Port = undefined,

    pub fn init(allocator: std.mem.Allocator) Bus {
        return .{ .cells = std.AutoHashMap(u32, Cell).init(allocator) };
    }

    /// The port `issuer` reaches the bus through. Its address is stable for
    /// as long as the bus is, which is what an MMIO hook needs.
    pub fn port(self: *Bus, issuer: Issuer) *Port {
        const slot = &self.ports[@backingInt(issuer)];
        slot.* = .{ .bus = self, .issuer = issuer };
        return slot;
    }

    pub fn deinit(self: *Bus) void {
        self.cells.deinit();
    }

    /// Register a block. Ranges are disjoint by construction: registering an
    /// overlapping one is a programming error and is refused here rather than
    /// silently shadowing whichever block was added first.
    pub fn add(self: *Bus, block: Block) Error!void {
        if (self.count == max_blocks) return Error.TooManyBlocks;
        if (block.base < base or block.end() > @as(u64, base) + size) return Error.OutsideWindow;
        for (self.blocks[0..self.count]) |existing| {
            if (block.base < existing.end() and existing.base < block.end()) return Error.OverlappingBlock;
        }
        self.blocks[self.count] = block;
        self.count += 1;
    }

    pub fn blockFor(self: *Bus, address: u32) ?*Block {
        for (self.blocks[0..self.count]) |*block| {
            if (block.covers(address)) return block;
        }
        return null;
    }

    pub fn read(self: *Bus, address: u32, width: u3) u32 {
        self.counters.reads += 1;
        const canonical = canonicalize(address);
        self.nonsecure = canonical != address;
        // An unclocked peripheral reads zero on silicon, whether or not this
        // emulator models the block behind the address.
        if (self.gate) |gate| {
            if (gate.drops(canonical, .read)) return 0;
        }
        if (self.blockFor(canonical)) |block| {
            self.counters.modelled += 1;
            return block.readFn(block.context, canonical, width);
        }
        const entry = self.cells.getOrPut(canonical) catch return 0;
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const cell = entry.value_ptr;
        if (cell.written) return mask(cell.value, width);
        cell.reads += 1;
        // Alternate so a ready-bit poll of either polarity completes.
        return if (cell.reads % 2 == 0) mask(0xFFFF_FFFF, width) else 0;
    }

    /// `times` more reads of `address`, counted without asking the block for
    /// a value, when its block says each would answer as the last did. Times
    /// 0 only asks. An unclocked or unmodelled address never repeats.
    pub fn repeat(self: *Bus, address: u32, width: u3, times: u64) bool {
        const canonical = canonicalize(address);
        if (self.gate) |gate| if (gate.stoppedFn(gate.context, canonical)) return false;
        const block = self.blockFor(canonical) orelse return false;
        const answer = block.repeatFn orelse return false;
        self.nonsecure = canonical != address;
        if (!answer(block.context, canonical, width, times)) return false;
        self.counters.reads += times;
        self.counters.modelled += times;
        return true;
    }

    /// The value at `address` as a report sees it: no counters, no
    /// clear-on-read, no step of the ready-bit alternation. Unclocked reads
    /// zero as silicon does. Null when the block keeps no peek or nothing
    /// was ever written to an unmodelled address (RA8EMU-631).
    pub fn peek(self: *Bus, address: u32, width: u3) ?u32 {
        const canonical = canonicalize(address);
        if (self.gate) |gate| if (gate.stoppedFn(gate.context, canonical)) return 0;
        if (self.blockFor(canonical)) |block| {
            const look = block.peekFn orelse return null;
            return look(block.context, canonical, width);
        }
        const cell = self.cells.get(canonical) orelse return null;
        return if (cell.written) mask(cell.value, width) else null;
    }

    pub fn write(self: *Bus, address: u32, width: u3, value: u32) void {
        self.counters.writes += 1;
        const canonical = canonicalize(address);
        self.nonsecure = canonical != address;
        if (self.gate) |gate| {
            if (gate.drops(canonical, .write)) return;
        }
        if (self.blockFor(canonical)) |block| {
            self.counters.modelled += 1;
            block.writeFn(block.context, canonical, width, value);
            return;
        }
        const entry = self.cells.getOrPut(canonical) catch return;
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.value = mask(value, width);
        entry.value_ptr.written = true;
    }

    /// How many distinct peripheral addresses the firmware has touched that
    /// nothing models. The porting worklist, in one number.
    pub fn unmodelledAddresses(self: *const Bus) usize {
        return self.cells.count();
    }
};

/// Fold the Non-secure alias onto the Secure address. One model answers both
/// windows, the way one block of silicon does.
pub fn canonicalize(address: u32) u32 {
    if (address >= ns_base and address < ns_base +% size) return address - ns_offset;
    return address;
}

fn mask(value: u32, width: u3) u32 {
    return switch (width) {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        else => value,
    };
}
