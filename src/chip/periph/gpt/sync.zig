//! GTSTR, GTSTP and GTCLR: the three registers that start, stop and clear
//! counters, and the fact that each of them names its channels by bit rather
//! than acting on the window it happened to be written through.
//!
//! They sit at +0x04, +0x08 and +0x0C of a channel window (`ra8_gpt_regs.h`
//! lines 60..62, "Software Start", "Software Stop", "Software Clear"), and
//! that placement is what makes them easy to get wrong. The window says
//! "channel n"; the register does not. Its bits are CSTRTn, CSTOPn and
//! CCLRn, one per channel in the bank, and a single access can name several
//! at once. `ra8_gpt.h` line 542 cites the page for exactly that:
//!
//!     HUM Ch 22.2.2 "GTSTR : General PWM Timer Software Start Register",
//!     p 901 -- writing multiple CSTRTn bits in one access starts those
//!     channels synchronously.
//!
//! THE OLD MODEL READ BIT 0 AND ACTED ON THE WINDOW. A store to GTSTR
//! started the channel whose window it landed in, if bit 0 of the low byte
//! was set, and dropped every other bit on the floor. For a bank where only
//! channel 0 is ever driven those two readings agree, which is why this held
//! up for so long: `ra8_gpt_start` and `ra8_gpt_init` both write the bare
//! `k_ra8_gpt_gtstr_start` (0x1, named "GTSTR.CSTRT0 write" at ra8_gpt.c
//! line 147) and every image in the corpus that starts a counter starts
//! channel 0.
//!
//! THE THREE-PHASE DRIVER IS THE CASE WHERE THEY DISAGREE, and it is the
//! whole point of the register. `ra8_gpt_three_phase_open` configures U, V
//! and W separately, then starts all three with one store through the U
//! channel's window (ra8_gpt.c lines 820..827):
//!
//!     /* Synchronous start: a single GTSTR write to the U-channel slot
//!        with all three CSTRTn bits set kicks all three counters on the
//!        same PCLKD edge. HUM Ch 22.2.2 "GTSTR" p 886. */
//!     u_reg->GTWP  = k_ra8_gtwp_key_unlock;
//!     u_reg->GTSTR = mask;
//!
//! where `mask` is an OR of `(1 << ch)` bits (ra8_gpt.c line 745), and the
//! close path stops the triple the same way with one GTSTP store of the
//! same mask (line 872). Against the old model that store started the U
//! channel and nothing else, so `gpt_three_phase_demo` ran one phase of
//! three: GPT0 counting with 24 overflows, GPT1 and GPT2 sitting at GTCNT 0
//! with running=no for the whole run, and a driver that had asked for three
//! synchronised counters was told it had them. Two thirds of a motor
//! commutation demo silently did not happen.
//!
//! A NARROW STORE NAMES THE CHANNELS ITS OWN LANES COVER. Since the bits are
//! channel-indexed, a byte store at +1 names channels 8..15, not 0..7, so
//! the access has to be placed inside the register rather than masked down
//! to its low byte. That falls out of `carried` and needs no special case.
//!
//! WHAT THIS EXPOSES RATHER THAN HIDES, and it is worth stating plainly: the
//! single-channel path writes CSTRT0 into its own window, so on this reading
//! `ra8_gpt_start(n)` for a non-zero n starts channel 0 instead of channel
//! n. That is the firmware's bug, not the model's, and it is latent across
//! the whole corpus because every single-channel start in the set is on
//! channel 0. A model that acted on the window would go on hiding it.
//!
//! THE SHAPE OF THAT BUG IS WORTH COUNTING, because it is invisible in the
//! report otherwise. A store made with per-window intent always names its
//! own channel; a store made with bank-wide intent through channel 0's
//! window names channel 0 among the rest. So a store that names some
//! channel but NOT the window it came through is neither: it is a per-window
//! write whose author thought the register was per-window. `ra8_gpt_deinit`
//! is exactly that (ra8_gpt.c lines 373..376):
//!
//!     reg->GTWP  = k_ra8_gtwp_key_unlock;
//!     reg->GTSTP = k_ra8_gpt_gtstp_stop;      /* 0x1 == CSTOP0 */
//!     reg->GTCR  = 0U;
//!
//! where `reg` is channel N's window. The bare 0x1 stops channel 0, not
//! channel N; channel N is stopped anyway by the `GTCR = 0` on the next
//! line, so the only lasting effect is that tearing down any channel
//! silently stops channel 0 too. `stray` counts those, and the report says
//! so, which turns a silent firmware bug into a printed line. It stays a
//! count and not a refusal: the store really does act on the channels it
//! names, and the model's job here is to say what happened, not to correct
//! the firmware's arithmetic.
//!
//! NOT MODELLED, AND NOT GUESSED: what these registers read back. On the
//! part they answer with the counting state of each channel; nothing in the
//! HAL ever reads one, and this tree carries no page for the read value, so
//! a read still comes off the window shadow exactly as it did before.
const clk = @import("clock.zig");
const win = @import("window.zig");

/// Which of the three a store asked for.
pub const Action = enum { start, stop, clear };

/// Which action register a channel-local offset belongs to, or null when the
/// offset is none of them.
pub fn which(local: u32) ?Action {
    if (local >= win.off.gtstr and local < win.off.gtstr + 4) return .start;
    if (local >= win.off.gtstp and local < win.off.gtstp + 4) return .stop;
    if (local >= win.off.gtclr and local < win.off.gtclr + 4) return .clear;
    return null;
}

/// Where a register starts, so an access can be placed inside it.
pub fn base(action: Action) u32 {
    return switch (action) {
        .start => win.off.gtstr,
        .stop => win.off.gtstp,
        .clear => win.off.gtclr,
    };
}

/// The channel bits an access carries, sitting where they belong in the
/// register: a byte store one in from the base names channels 8..15.
pub fn carried(lane: u32, width: u3, value: u32) u32 {
    const kept: u32 = if (width >= 4)
        ~@as(u32, 0)
    else
        (@as(u32, 1) << @intCast(@as(u32, width) * 8)) - 1;
    const shift: u5 = @intCast(lane * 8);
    return (value & kept) << shift;
}

/// What the bank did with the three registers, so the report can tell a
/// synchronous start from fourteen separate ones.
pub const Sync = struct {
    /// Channel bits acted on, summed over every access.
    acted: u32 = 0,
    /// Accesses that named more than one channel, the synchronous case.
    together: u32 = 0,
    /// Bits naming a channel this bank does not carry.
    absent: u32 = 0,
    /// Accesses that named a channel but not the window they came through,
    /// the per-window-intent bug described in the header.
    stray: u32 = 0,

    pub fn quiet(self: *const Sync) bool {
        return self.acted == 0 and self.together == 0 and
            self.absent == 0 and self.stray == 0;
    }
};

/// Take one access and act on every channel it names. `channels` is the
/// bank's own array. What a bit does lives here rather than on the channel,
/// so the whole CSTRTn rule reads in one place.
pub fn dispatch(
    state: *Sync,
    action: Action,
    bits: u32,
    window: usize,
    channels: anytype,
) void {
    var named: u32 = 0;
    for (channels, 0..) |*channel, index| {
        if (bits & (@as(u32, 1) << @intCast(index)) == 0) continue;
        named += 1;
        switch (action) {
            .start => channel.cr |= clk.field.cst,
            .stop => channel.cr &= ~clk.field.cst,
            .clear => channel.cnt = 0,
        }
    }
    state.acted +%= named;
    if (named > 1) state.together +%= 1;
    const present: u32 = (@as(u32, 1) << @intCast(channels.len)) - 1;
    state.absent +%= @popCount(bits & ~present);
    const own: u32 = @as(u32, 1) << @intCast(window);
    if (bits != 0 and bits & own == 0) state.stray +%= 1;
}
