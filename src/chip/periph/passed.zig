//! Pends that were ready, lost the pick, and stayed pending.
//!
//! WHY THIS EXISTS. src/chip/periph/nvic/nvic.zig's `pick` walks everything pending and
//! returns the most urgent one. The others are dropped on the floor: no
//! counter moved, no line printed, and from the report they were never ready
//! at all. src/chip/periph/held.zig does NOT cover them. `held.outranked` is a
//! different question, whether a RUNNING handler outranks the winner, and on
//! `threadx_blink` it fires twice in a thousand modelled milliseconds while
//! the thing actually going wrong happens constantly.
//!
//! WHAT IT WAS BUILT FOR. `threadx_blink` runs its thread body about three
//! times per wake where the board runs it once. ThreadX writes SHPR3 to
//! 0x40FF0000, so SysTick sits at priority 0x40 and PendSV at 0xFF, and
//! SysTick is pending at very nearly every boundary. Any PendSV the scheduler
//! raises therefore loses the pick, every time, and nothing said so: the run
//! reported 999 SysTick entries, 4 PendSV entries, 16 held, and no sign that
//! a PendSV had been standing there all along. That is the shape this counts.
//!
//! A loss is NOT a bug on its own. Losing one pick is the architecture
//! working: the winner runs and the loser is taken next, which is what
//! tail-chaining at a run boundary is for. What matters is a pend that
//! loses CONSECUTIVE boundaries, so the run of losses is tracked as well as
//! the count.

/// Pends that lost a pick, and how long the same one kept losing.
pub const Passed = struct {
    /// Candidates dropped by a pick because something outranked them.
    losses: u64 = 0,
    /// The first exception to lose a pick, and what beat it. Zero when
    /// nothing ever lost.
    loser: u16 = 0,
    /// What beat `loser` the first time.
    winner: u16 = 0,
    /// Boundaries the current loser has lost in a row.
    run: u64 = 0,
    /// The longest such run in the whole run of the image.
    longest: u64 = 0,
    /// Which exception owns `longest`.
    starved: u16 = 0,
    /// `losses` as it stood at the end of the previous boundary, so a
    /// boundary that lost nothing can be told from one that did.
    marked: u64 = 0,

    /// Record that `lost` was ready and `won` was taken instead.
    pub fn lost(self: *Passed, number: u16, won: u16) void {
        self.losses +%= 1;
        if (self.loser == 0) {
            self.loser = number;
            self.winner = won;
        }
        if (self.starved != number) {
            self.starved = number;
            self.run = 0;
        }
        self.run += 1;
        if (self.run > self.longest) self.longest = self.run;
    }

    /// Close a boundary. A boundary where nothing lost ends whatever run was
    /// going: the pend got taken, or stopped being pending, either way it is
    /// no longer starving. Called once per pick, by the pick that counts.
    pub fn boundary(self: *Passed) void {
        if (self.losses == self.marked) self.run = 0;
        self.marked = self.losses;
    }

    pub fn quiet(self: *const Passed) bool {
        return self.losses == 0;
    }
};
