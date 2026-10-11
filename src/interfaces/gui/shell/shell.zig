//! shell: the files of src/interfaces/gui/shell/.

pub const board = @import("board/board.zig");
pub const camera = @import("camera/camera.zig");
pub const console = @import("console.zig");
pub const devices = @import("devices.zig");
pub const fault = @import("fault.zig");
/// The shell's pane chrome and text field, drawn by ui/shell/.
pub const field = @import("../ui/shell/field.zig");
pub const frame = @import("../ui/shell/frame.zig");
pub const loop = @import("loop.zig");
pub const main = @import("main.zig");
pub const memory = @import("memory.zig");
pub const panes = @import("panes.zig");
pub const plug = @import("plug.zig");
pub const registers = @import("registers.zig");
pub const stack = @import("stack.zig");
pub const run = @import("run.zig");
pub const startup = @import("startup.zig");
pub const theme = @import("theme.zig");
pub const time = @import("time.zig");
pub const titles = @import("titles.zig");
