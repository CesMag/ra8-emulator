//! The peripheral clock source selects and the SREQ -> SRDY handshake.
//!
//! Seven 8-bit registers scattered through the SYSC window pick the source
//! clock for a peripheral that runs off its own branch rather than off PCLK:
//!
//!   SCICKCR    (+0x055)  SCI_B TCLK             (HUM Ch 9.2.54 p 368)
//!   USBCKCR    (+0x074)  USB-FS module clock
//!   OCTACKCR   (+0x075)  Octal-SPI clock        (HUM Ch 9.2.45 p 360)
//!   CANFDCKCR  (+0x076)  CAN-FD core clock      (HUM Ch 9.2.46 p 366)
//!   USB60CKCR  (+0x077)  USBHS 60 MHz clock
//!   ESWCKCR    (+0x0DB)  Ethernet-switch core clock
//!   ESWPCKCR   (+0x0DC)  Ethernet-PHY interface clock
//!
//! They share one layout, and the firmware says so in three separate places:
//! ra8_xspi.c and ra8_canfd.c both reach for `k_ra8_usbckcr_bit_sreq` and
//! `k_ra8_usbckcr_bit_srdy` rather than defining their own; ra8_system_regs.h
//! says of ESWPCKCR "layout identical to ESWCKCR" and of ESWCKCR "layout
//! identical to USB60CKCR"; and ra8_cgc_eswclk.c's own step 1 comment reads
//! "ESWCKCR / ESWPCKCR / USBCKCR / USB60CKCR all share the same" handshake.
//! SEL is bits 3:0, SREQ is bit 6, and SRDY is bit 7 and is read only.
//!
//! A SOURCE IS NOT SWITCHED BY WRITING SEL. HUM Ch 9 "Clock Selection
//! Switching Procedure" makes it a handshake, and ra8_cgc.h writes the steps
//! out: assert SREQ, WAIT FOR SRDY TO READ 1 (the branch is now gated and
//! therefore switchable), write the divider, write SEL with SREQ still set,
//! drop SREQ, then WAIT FOR SRDY TO READ 0 (the new source is running). Both
//! waits are bounded spins, and every caller gives them a budget and then
//! gives up: 200,000 iterations in ra8_cgc_usb.c and ra8_cgc_eswclk.c,
//! 0x40000 in ra8_cgc.c's internal_route_sciclk, each returning
//! k_ra8_err_hw_timeout when they run out.
//!
//! Nothing modelled these registers, so they fell through to the sparse
//! register file, which answers the last word written. SRDY is bit 7 and no
//! driver ever writes it, so it read 0 forever: the first wait, for SRDY = 1,
//! spun out its whole budget and every one of these paths returned a hardware
//! timeout before it reached the second wait. ra8_cgc_usbfs_clock_enable,
//! ra8_cgc_usbhs_clock_enable, the XSPI clock bring-up in ra8_xspi.c, the
//! CAN-FD one in ra8_canfd.c, internal_route_sciclk and
//! internal_switch_eswcr_to_pll1p all failed the same way and for the same
//! reason.
//!
//! SRDY simply follows SREQ here: the branch gates and ungates in no time, so
//! a driver polling for 1 and then for 0 makes progress on both, and a driver
//! that reads SRDY without having asked for anything still reads 0.
//!
//! THE THREE WINDOWS ARE THREE WINDOWS, not one span with holes in it. The
//! registers between them belong to other blocks and to the sparse file, and
//! claiming 0x055 through 0x0DC wholesale would swallow SCICKDIVCR,
//! ESWCKDIVCR and everything else in between. Each run of adjacent selects
//! gets its own bus entry and they share one model.
//!
//! NOT MODELLED, AND NOT GUESSED: the module-stop precondition. HUM Ch 9
//! requires the dependent peripheral to be in module-stop before SREQ is
//! asserted when the divider is changing, and ra8_cgc_usb.c says in so many
//! words that "if the caller has already released MSTPB12 (USBHS) the
//! SREQ->SRDY handshake silently hangs". Honouring that needs the module-stop
//! bit for each of these branches, and src/chip/periph/mstp/mstp.zig carries no family
//! for either USB controller, so a hang modelled here would be a guess for
//! half the window. Nor is the ESWM power domain asked: ra8_cgc_eswclk.c
//! drops PDCTRESWM.PDDE before it switches, and src/chip/periph/pdctr.zig models
//! the GRAPHICS domain only, so the ESWM one has no model to ask. No clock
//! RATE is derived from SEL either: the value is retained and reported,
//! nothing downstream reads it, and the dividers at +0x054, +0x06C, +0x06F
//! and +0x0D5 are not these registers.
const periph = @import("registry.zig");
const prcr = @import("prcr.zig");

/// One clock source select: where it answers and what to call it.
pub const Slot = struct {
    address: u32,
    name: []const u8,
};

/// Every select this model answers for, in address order.
pub const slots = [_]Slot{
    .{ .address = 0x4001_E055, .name = "SCICKCR" },
    .{ .address = 0x4001_E074, .name = "USBCKCR" },
    .{ .address = 0x4001_E075, .name = "OCTACKCR" },
    .{ .address = 0x4001_E076, .name = "CANFDCKCR" },
    .{ .address = 0x4001_E077, .name = "USB60CKCR" },
    .{ .address = 0x4001_E0DB, .name = "ESWCKCR" },
    .{ .address = 0x4001_E0DC, .name = "ESWPCKCR" },
};

/// A run of adjacent selects, which is what goes on the bus. The gaps
/// between the runs belong to other registers and are left alone.
pub const Window = struct {
    base: u32,
    span: u32,
};

pub const windows = [_]Window{
    .{ .base = 0x4001_E055, .span = 1 },
    .{ .base = 0x4001_E074, .span = 4 },
    .{ .base = 0x4001_E0DB, .span = 2 },
};

/// Which select answers at an address, if any.
pub fn indexOf(address: u32) ?usize {
    for (&slots, 0..) |one, index| {
        if (one.address == address) return index;
    }
    return null;
}

/// The one layout all seven share (ra8_system_regs.h, ra8_usbckcr_bit_t).
pub const field = struct {
    /// SEL, bits 3:0: the source clock codepoint.
    pub const sel: u8 = 0x0F;
    /// SREQ, bit 6: ask for a switch.
    pub const sreq: u8 = 0x40;
    /// SRDY, bit 7: read-only, the branch is gated and switchable.
    pub const srdy: u8 = 0x80;
};

/// The group these sit behind: PRC0, the clock generation circuit.
pub const guard: u16 = prcr.group.cgc;

/// One clock source select: the retained bits, and what the handshake did.
pub const Select = struct {
    sel: u8 = 0,
    requested: bool = false,
    /// Times SREQ went up, which is one half-handshake each.
    requests: u32 = 0,
    /// Times SREQ came back down, which is the moment the new source runs.
    switches: u32 = 0,

    /// SRDY is not stored: it is what SREQ means right now.
    pub fn ready(self: *const Select) bool {
        return self.requested;
    }

    pub fn value(self: *const Select) u8 {
        var out = self.sel;
        if (self.requested) out |= field.sreq | field.srdy;
        return out;
    }

    /// SEL lands either way, which is what lets the driver write source and
    /// SREQ together in one store and then drop SREQ in the next.
    pub fn store(self: *Select, written: u8) void {
        const wants = written & field.sreq != 0;
        if (wants and !self.requested) self.requests +%= 1;
        if (!wants and self.requested) self.switches +%= 1;
        self.sel = written & field.sel;
        self.requested = wants;
    }
};

/// Every select as one model, with PRC0 asked before any store. The three
/// runs of adjacent registers go on the bus separately and share this.
pub const Ckcr = struct {
    /// The board's live protection model, not a copy of it.
    protection: *const prcr.Prcr,
    selects: [slots.len]Select = @splat(Select{}),
    /// Stores dropped because PRCR.PRC0 was locked.
    dropped_locked: u32 = 0,

    pub fn init(protection: *const prcr.Prcr) Ckcr {
        return .{ .protection = protection };
    }

    /// A run that never switched a branch has nothing to narrate.
    pub fn quiet(self: *const Ckcr) bool {
        if (self.dropped_locked != 0) return false;
        for (&self.selects) |*one| {
            if (one.requests != 0 or one.switches != 0) return false;
        }
        return true;
    }

    /// How many completed handshakes one select has behind it: SREQ up,
    /// SRDY read back, SREQ down. Callers that need to know whether a
    /// branch's clock was ever declared stable ask this rather than reading
    /// SEL, which says what was picked and not whether it settled.
    pub fn completed(self: *const Ckcr, address: u32) u32 {
        const index = indexOf(address) orelse return 0;
        return self.selects[index].switches;
    }

    pub fn read(self: *Ckcr, address: u32, width: u3) u32 {
        _ = width;
        const index = indexOf(address) orelse return 0;
        return self.selects[index].value();
    }

    pub fn write(self: *Ckcr, address: u32, width: u3, value: u32) void {
        _ = width;
        const index = indexOf(address) orelse return;
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        self.selects[index].store(@truncate(value));
    }

    /// One bus entry per run of adjacent selects.
    pub fn block(self: *Ckcr, which: usize) periph.Block {
        return .{
            .name = "CKCR",
            .base = windows[which].base,
            .size = windows[which].span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Ckcr = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Ckcr = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
