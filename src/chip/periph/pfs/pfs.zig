//! The Pin Function Select array, and the write protect standing in front of
//! it.
//!
//! (PFS at 0x4040_0800, R_PMISC at 0x4040_0D00, HUM Ch 20.) Every pin has its
//! own 32-bit PmnPFS holding direction, output level, pull-up, drive strength,
//! IRQ and analog enables, and the peripheral function routed to it. Pins are
//! addressed flat, (port * 16) + pin, four bytes each, fifteen ports of
//! sixteen.
//!
//! WHAT THIS BLOCK IS FOR is not the fields, which nothing here reads yet: it
//! is the gate. A PmnPFS write only lands while PWPRS.PFSWE stands, and
//! skipping the unlock does not fault and does not report. The write silently
//! goes nowhere and the driver carries on believing the pin is routed, which
//! is the single worst way for a pin bring-up bug to present. See
//! `protect.zig` for the two-step sequence and for why the Secure path is
//! the one that gates.
//!
//! Before this block existed the whole window fell to the bus catch-all, which
//! stores whatever it is handed and reads it back, so every pin write landed
//! whether or not the firmware had unlocked.
//!
//! THE ONE ORDERING RULE PmnPFS HAS lives in `route.zig`: a pin is meant
//! to be returned to GPIO mode before a new peripheral function is programmed
//! onto it, and a store that moves a routed pin straight to a different
//! function leaves the pad driving the old one while the new select decodes.
//! That store is taken here exactly as the part takes it, and counted, because
//! the glitch is invisible from the firmware side.
//!
//! THE REST OF PMISC IS A SHADOW and deliberately so. PFENET and PMSAR are in
//! the same window, nothing in the corpus touches either, and PMSAR in
//! particular would change which of the two write-protect paths owns a port.
//! Modelling it on no evidence would be guessing at the thing the gate turns
//! on, so it stores and reads back and nothing more.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");
const protect = @import("protect.zig");
const route = @import("route.zig");

pub const win_base: u32 = 0x4040_0800;
pub const win_span: u32 = 0x580;

pub const limits = struct {
    pub const port_count: u32 = 15;
    pub const pin_count: u32 = 16;
    pub const entry_count: u32 = port_count * pin_count;
};

pub const region = struct {
    /// The PmnPFS array runs from the base to here.
    pub const pfs_end: u32 = limits.entry_count * 4;
    /// R_PMISC, offset inside this window.
    pub const pmisc: u32 = 0x4040_0D00 - win_base;
    pub const pmisc_words: u32 = 32;
};

/// The pin array, the gate, and what the run should say about both.
pub const Pfs = struct {
    entries: [limits.entry_count]u32 = @splat(0),
    misc: [region.pmisc_words]u32 = @splat(0),
    guard: protect.Protect = .{},
    ordering: route.Route = .{},
    /// Pin writes that landed, so a refusal count has something to sit beside.
    programmed: u32 = 0,

    pub fn init() Pfs {
        return .{};
    }

    pub fn quiet(self: *const Pfs) bool {
        return self.programmed == 0 and self.guard.quiet() and self.ordering.quiet();
    }

    /// The flat index a pin sits at, the firmware's own (port * 16) + pin.
    pub fn indexOf(port: u32, at: u32) u32 {
        return port * limits.pin_count + at;
    }

    /// The address of one PmnPFS, for tests and for anything that would
    /// otherwise do the arithmetic itself.
    pub fn pinAddress(port: u32, at: u32) u32 {
        return win_base + indexOf(port, at) * 4;
    }

    pub fn pin(self: *const Pfs, port: u32, at: u32) u32 {
        return self.entries[indexOf(port, at)];
    }

    pub fn read(self: *Pfs, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset < region.pfs_end) {
            return lanes.part(self.entries[offset / 4], lanes.lane(offset), width);
        }
        if (offset >= region.pmisc) {
            const inside = offset - region.pmisc;
            if (inside == protect.off.pwpr or inside == protect.off.pwprs) {
                return self.guard.read(inside);
            }
            const index = inside / 4;
            if (index < region.pmisc_words) {
                return lanes.part(self.misc[index], lanes.lane(offset), width);
            }
        }
        return 0;
    }

    pub fn write(self: *Pfs, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset < region.pfs_end) {
            if (!self.guard.allows()) {
                self.guard.refuse();
                return;
            }
            const index = offset / 4;
            const standing = self.entries[index];
            const merged = lanes.merge(standing, lanes.lane(offset), width, value);
            self.ordering.observe(standing, merged);
            self.entries[index] = merged;
            self.programmed +%= 1;
            return;
        }
        if (offset >= region.pmisc) {
            const inside = offset - region.pmisc;
            if (inside == protect.off.pwpr or inside == protect.off.pwprs) {
                self.guard.write(inside, @truncate(value));
                return;
            }
            const index = inside / 4;
            if (index < region.pmisc_words) {
                self.misc[index] = lanes.merge(self.misc[index], lanes.lane(offset), width, value);
            }
        }
    }

    pub fn block(self: *Pfs) periph.Block {
        return .{
            .name = "PFS/PMISC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Pfs = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Pfs = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
