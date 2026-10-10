//! MIPI DSI host: the panel side of the D-PHY, so the link status the
//! command path reads is the link it actually programmed.
//!
//! One window at 0x4034_6000 (ra8_mipi_dsi_regs.h, k_ra8_mipi_dsi_base_addr_s,
//! below the D-PHY at 0x4034_6C00 this block drives). Nothing modelled it, so
//! every access fell through to the sparse register file, and that register
//! file answers an unwritten cell by alternating 0 and all-ones so a ready-bit
//! poll of either polarity completes. For a wait loop that is a kindness. For
//! a status word somebody DECODES it is poison.
//!
//! THE BUG WITH TEETH. LINKSR at +0x010 is read-only and the firmware never
//! writes it, so it alternated. internal_check_link_state (ra8_mipi_dsi_cmd.c
//! line 282) reads it once per ra8_mipi_dsi_send_command and rejects the
//! command outright when SQ0RUN or SQ1RUN is up, or when VRUN is up and the
//! command is low-power. On the all-ones read every one of those bits is up,
//! so every other send_command came back busy or invalid-state on a link that
//! was idle, and which one depended only on how many times anything else had
//! read the cell first.
//!
//! Quieter, same cause: ra8_mipi_dsi_video_stop waits for VMSR.STOP and
//! ra8_mipi_dsi_hs_clock_start waits for PLSR.CLLP2HS, and the alternating
//! cell satisfied both on the second poll whether or not video had ever run
//! or the clock had ever started.
//!
//!   ISR    (+0x000)  interrupt status
//!   LINKSR (+0x010)  link status, read-only, derived here
//!   TXSETR (+0x100)  lane enable and count
//!   HSCLKSETR (+0x104)  HS clock start and continuous mode
//!   ULPSCR (+0x10C)  ULPS enter and exit pulses
//!   RSTCR  (+0x110)  software reset control
//!   RSTSR  (+0x114)  software reset status, read-only, derived here
//!   PLSR/PLSCR (+0x320/+0x324)  PHY lane status and its clear
//!   VMSET0R (+0x400)  video mode start and stop
//!   VMSR/VMSCR (+0x410/+0x414)  video mode status and its clear
//!   SQCH0SET0R (+0x5C0), SQCH0SR/SCR (+0x5D0/+0x5D4)
//!   SQCH1SET0R (+0x600), SQCH1SR/SCR (+0x610/+0x614)
//!
//! NOT MODELLED, AND NOT GUESSED: the link itself. No panel answers here, so
//! a sequence channel completes inside the store that starts it rather than
//! after a modelled transfer time, nothing ever lands in the receive slots,
//! and the ack-and-error and fatal-error latches stay clear because only a
//! peer can raise them. Neither tree carries a lane settle time or a
//! descriptor execution time, so inventing one would only move the lie.
//! Descriptors, payload words and the timeout registers are a plain shadow:
//! the driver reads back what it wrote, which is what it does on silicon too.
const periph = @import("../registry.zig");
const rule = @import("dsi_link.zig");

/// Host geometry. The bus folds the Non-secure alias at 0x5034_6000 onto
/// this base.
pub const win_base: u32 = 0x4034_6000;
/// k_ra8_mipi_dsi_window_bytes, SQCH1DSC[7] inclusive.
pub const win_span: u32 = 0x880;

/// The status rule, re-exported so callers reach it through here.
pub const status = rule;

pub const off = struct {
    pub const linksr: u32 = 0x010;
    pub const hsclksetr: u32 = 0x104;
    pub const ulpscr: u32 = 0x10C;
    pub const rstcr: u32 = 0x110;
    pub const rstsr: u32 = 0x114;
    pub const plsr: u32 = 0x320;
    pub const plscr: u32 = 0x324;
    pub const vmset0r: u32 = 0x400;
    pub const vmsr: u32 = 0x410;
    pub const vmscr: u32 = 0x414;
    pub const sqch0set0r: u32 = 0x5C0;
    pub const sqch0sr: u32 = 0x5D0;
    pub const sqch0scr: u32 = 0x5D4;
    pub const sqch1set0r: u32 = 0x600;
    pub const sqch1sr: u32 = 0x610;
    pub const sqch1scr: u32 = 0x614;
};

/// One sequence channel: the descriptor engine the command path pulses.
pub const Channel = struct {
    /// What SQCHnSR reports, latched until SQCHnSCR takes it down.
    latched: u32 = 0,
    /// Sequences started on this channel.
    sends: u32 = 0,
    /// Starts taken with no HS clock running, which on a bench is a command
    /// posted into a link that cannot carry it.
    dark_sends: u32 = 0,

    /// A sequence runs to completion inside the store that starts it, so
    /// RUNNING is never observable and the finish flags are up on the next
    /// read. The alternative would be a transfer time neither tree states.
    fn start(self: *Channel, clock_running: bool) void {
        self.sends +%= 1;
        if (!clock_running) self.dark_sends +%= 1;
        self.latched |= rule.sequence.finished;
    }

    fn clear(self: *Channel, written: u32) void {
        self.latched &= ~written;
    }
};

/// The host: the registers this model interprets, a shadow for the rest of
/// the window, and what the run should be told about it.
pub const MipiDsi = struct {
    hsclksetr: u32 = 0,
    vmset0r: u32 = 0,
    rstcr: u32 = 0,
    /// PLSR event bits, latched until PLSCR clears them.
    phy_latched: u32 = 0,
    /// VMSR event bits, latched until VMSCR clears them.
    video_latched: u32 = 0,
    video_running: bool = false,
    clock_ulps: bool = false,
    data_ulps: bool = false,
    channel: [2]Channel = .{ .{}, .{} },
    /// Every other word in the window.
    shadow: [win_span]u8 = @splat(0),
    /// Reads of LINKSR, which is the gate every command passes through.
    link_reads: u32 = 0,
    /// Reads of PLSR and VMSR, which are the two driver wait loops.
    phy_polls: u32 = 0,
    video_polls: u32 = 0,
    /// Stores aimed at a read-only word.
    refused: u32 = 0,
    hs_starts: u32 = 0,
    hs_stops: u32 = 0,
    video_starts: u32 = 0,
    video_stops: u32 = 0,
    /// Stops asked for with video not running.
    idle_stops: u32 = 0,
    resets: u32 = 0,
    ulps_entries: u32 = 0,
    ulps_exits: u32 = 0,

    pub fn init() MipiDsi {
        return .{};
    }

    pub fn quiet(self: *const MipiDsi) bool {
        return self.link_reads == 0 and self.phy_polls == 0 and self.video_polls == 0 and
            self.refused == 0 and self.hs_starts == 0 and self.video_starts == 0 and
            self.resets == 0 and self.sends() == 0;
    }

    pub fn sends(self: *const MipiDsi) u32 {
        return self.channel[0].sends +% self.channel[1].sends;
    }

    pub fn darkSends(self: *const MipiDsi) u32 {
        return self.channel[0].dark_sends +% self.channel[1].dark_sends;
    }

    pub fn lanes(self: *const MipiDsi) rule.Lanes {
        return .{
            .hs_clock = rule.clockRunning(self.hsclksetr),
            .clock_ulps = self.clock_ulps,
            .data_ulps = self.data_ulps,
        };
    }

    pub fn continuous(self: *const MipiDsi) bool {
        return rule.continuousClock(self.hsclksetr);
    }

    pub fn inReset(self: *const MipiDsi) bool {
        return rule.inReset(self.rstcr);
    }

    /// LINKSR as it stands right now, without counting a read.
    pub fn linksr(self: *const MipiDsi) u32 {
        return rule.linkWord(false, false, self.video_running, self.lanes());
    }

    pub fn plsr(self: *const MipiDsi) u32 {
        return rule.phyWord(self.lanes(), self.phy_latched);
    }

    pub fn vmsr(self: *const MipiDsi) u32 {
        return rule.videoWord(self.video_running, self.video_latched);
    }

    fn readWord(self: *MipiDsi, local: u32) u32 {
        return switch (local) {
            off.linksr => blk: {
                self.link_reads +%= 1;
                break :blk self.linksr();
            },
            off.hsclksetr => self.hsclksetr,
            off.rstcr => self.rstcr,
            off.rstsr => rule.resetWord(self.inReset(), self.lanes()),
            off.plsr => blk: {
                self.phy_polls +%= 1;
                break :blk self.plsr();
            },
            off.vmset0r => self.vmset0r,
            off.vmsr => blk: {
                self.video_polls +%= 1;
                break :blk self.vmsr();
            },
            off.sqch0sr => self.channel[0].latched,
            off.sqch1sr => self.channel[1].latched,
            else => self.shadowWord(local),
        };
    }

    fn writeWord(self: *MipiDsi, local: u32, value: u32) void {
        switch (local) {
            // Read-only: the host owns these.
            off.linksr, off.rstsr, off.plsr, off.vmsr, off.sqch0sr, off.sqch1sr => self.refused +%= 1,
            off.hsclksetr => self.setClock(value),
            off.ulpscr => self.pulseUlps(value),
            off.rstcr => self.setReset(value),
            off.plscr => self.phy_latched &= ~value,
            off.vmset0r => self.setVideo(value),
            off.vmscr => self.video_latched &= ~value,
            off.sqch0set0r => self.setSequence(0, value),
            off.sqch0scr => self.channel[0].clear(value),
            off.sqch1set0r => self.setSequence(1, value),
            off.sqch1scr => self.channel[1].clear(value),
            else => self.setShadowWord(local, value),
        }
    }

    /// The clock-lane transition latches on the edge, not on the level: the
    /// driver writes HSCLKSETR once and then waits for the matching event,
    /// so a second identical store must not re-arm what it already consumed.
    fn setClock(self: *MipiDsi, value: u32) void {
        const was_on = rule.clockRunning(self.hsclksetr);
        self.hsclksetr = value;
        const now_on = rule.clockRunning(value);
        if (!was_on and now_on) {
            self.hs_starts +%= 1;
            self.phy_latched |= rule.phy.cllp2hs;
        } else if (was_on and !now_on) {
            self.hs_stops +%= 1;
            self.phy_latched |= rule.phy.clhs2lp;
        }
    }

    /// ULPSCR is four pulses rather than a held state, and the driver only
    /// ever writes the ones it means, so each is taken on its own.
    fn pulseUlps(self: *MipiDsi, value: u32) void {
        if (value & rule.ulps.clent != 0) {
            self.clock_ulps = true;
            self.phy_latched |= rule.phy.clulpent;
            self.ulps_entries +%= 1;
        }
        if (value & rule.ulps.clexit != 0) {
            self.clock_ulps = false;
            self.phy_latched |= rule.phy.clulpext;
            self.ulps_exits +%= 1;
        }
        if (value & rule.ulps.dlent != 0) {
            self.data_ulps = true;
            self.phy_latched |= rule.phy.dlulpent;
            self.ulps_entries +%= 1;
        }
        if (value & rule.ulps.dlexit != 0) {
            self.data_ulps = false;
            self.phy_latched |= rule.phy.dlulpext;
            self.ulps_exits +%= 1;
        }
    }

    /// RSTCR.SWRST is held, not auto-clearing: ra8_mipi_dsi_soft_reset writes
    /// it and then writes zero itself. Releasing it puts the link back where
    /// reset leaves it, which is everything down and nothing latched.
    fn setReset(self: *MipiDsi, value: u32) void {
        const was_held = self.inReset();
        self.rstcr = value;
        if (!was_held and self.inReset()) {
            self.resets +%= 1;
            self.hsclksetr = 0;
            self.vmset0r = 0;
            self.video_running = false;
            self.clock_ulps = false;
            self.data_ulps = false;
            self.phy_latched = 0;
            self.video_latched = 0;
            self.channel[0].latched = 0;
            self.channel[1].latched = 0;
        }
    }

    fn setVideo(self: *MipiDsi, value: u32) void {
        self.vmset0r = value;
        if (rule.startRequested(value)) {
            self.video_running = true;
            self.video_latched |= rule.video.virdy;
            self.video_starts +%= 1;
        }
        if (rule.stopRequested(value)) {
            if (!self.video_running) self.idle_stops +%= 1;
            self.video_running = false;
            self.video_latched |= rule.video.stop;
            self.video_stops +%= 1;
        }
    }

    fn setSequence(self: *MipiDsi, index: usize, value: u32) void {
        self.setShadowWord(if (index == 0) off.sqch0set0r else off.sqch1set0r, value);
        if (!rule.sequenceStarted(value)) return;
        self.channel[index].start(rule.clockRunning(self.hsclksetr));
    }

    fn shadowWord(self: *const MipiDsi, local: u32) u32 {
        var value: u32 = 0;
        var index: u32 = 0;
        while (index < 4 and local + index < win_span) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            value |= @as(u32, self.shadow[local + index]) << shift;
        }
        return value;
    }

    fn setShadowWord(self: *MipiDsi, local: u32, value: u32) void {
        var index: u32 = 0;
        while (index < 4 and local + index < win_span) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            self.shadow[local + index] = @truncate(value >> shift);
        }
    }

    /// Every register here is a 32-bit word, so a narrower access is served
    /// out of the word it lands in rather than pretending the window is a
    /// byte array.
    pub fn read(self: *MipiDsi, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const word = offset & ~@as(u32, 3);
        const shift: u5 = @intCast((offset & 3) * 8);
        const value = self.readWord(word) >> shift;
        return switch (width) {
            1 => value & 0xFF,
            2 => value & 0xFFFF,
            else => value,
        };
    }

    pub fn write(self: *MipiDsi, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const word = offset & ~@as(u32, 3);
        if (width == 4 and offset == word) {
            self.writeWord(word, value);
            return;
        }
        const shift: u5 = @intCast((offset & 3) * 8);
        const mask: u32 = switch (width) {
            1 => @as(u32, 0xFF) << shift,
            2 => @as(u32, 0xFFFF) << shift,
            else => 0xFFFF_FFFF,
        };
        const merged = (self.readWordQuiet(word) & ~mask) | ((value << shift) & mask);
        self.writeWord(word, merged);
    }

    /// The same read the bus would do, without counting a poll: a byte store
    /// into a word is not firmware waiting on the link.
    fn readWordQuiet(self: *MipiDsi, local: u32) u32 {
        return switch (local) {
            off.linksr => self.linksr(),
            off.plsr => self.plsr(),
            off.vmsr => self.vmsr(),
            else => self.readWord(local),
        };
    }

    pub fn block(self: *MipiDsi) periph.Block {
        return .{
            .name = "MIPI-DSI",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *MipiDsi = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *MipiDsi = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
