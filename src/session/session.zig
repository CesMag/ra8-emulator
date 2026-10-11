//! What every debugger session shares: the errors a command can end in,
//! the run limits, whether a script wants more, and the poll gdb's
//! interrupt comes through.
//!
//! The session is src/session/zig/session.zig, driven by src/session/zig/script.zig
//! for scripts and by the GDB server in src/interfaces/gdb for gdb.
pub const Error = error{ AlreadyRunning, NoSymbols, Unresolved, CoreNotAttached };

pub const limits = struct {
    /// Instructions one run may take before it gives up and reports where
    /// it got to. A stop that never comes must not hang a script.
    pub const default_budget: usize = 1_000_000;
    /// Bytes a watch covers: one word, the width of the variables worth
    /// watching in this firmware.
    pub const watch_bytes: u32 = 4;
};

/// Whether the session wants more commands.
pub const Outcome = enum { more, quit };

/// Asked between run chunks whether the run should stop: gdb's interrupt.
pub const Poll = struct {
    context: *anyopaque,
    check: *const fn (*anyopaque) bool,
};
