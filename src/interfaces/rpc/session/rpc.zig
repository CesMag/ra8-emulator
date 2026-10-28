//! Session RPC messages carried by the shared RA8 wire protocol (RA8EMU-194).
const rpc = @import("ra8_rpc_wire");

pub const protocol_version: u16 = 1;
/// Bit 0: LCD dirty rectangles. Bit 1: plug, unplug and fault methods.
/// Bit 2: advance. Bit 3: snapshot and restore. Bit 6: stack. Bit 7: rtc.
/// Bit 8: input. Bit 9: backtrace. Bit 10: periph. Bit 11: folded.
/// Bit 12: break by name. Bit 13: board parts.
/// Bit 14: the locals_at op (RA8EMU-1187), locals at a chosen frame.
/// Bit 15: the transport topic and advance_async (RA8EMU-1196, slice 14):
/// a host whose frame loop owns the pump answers advance_async by queueing
/// and reports the completion on the transport topic.
pub const capabilities: u32 = 0x0000_7FFF;
/// Capability bit 15, the transport topic. Hosted servers OR it into the
/// handshake when the frame loop owns the pump; `serve` does not.
pub const transport_cap: u32 = 0x0000_8000;
pub const max_payload = 1_048_576;

pub const app_codes = struct {
    pub const refused: u16 = 0x0100;
    pub const no_core: u16 = 0x0101;
    pub const too_long: u16 = 0x0102;
    pub const history: u16 = 0x0103;
};

pub const Method = enum(u16) {
    load = 0x0100,
    run = 0x0101,
    pause = 0x0102,
    step = 0x0103,
    set_speed = 0x0104,
    read_register = 0x0105,
    write_register = 0x0106,
    read_memory = 0x0107,
    write_memory = 0x0108,
    set_breakpoint = 0x0109,
    clear_breakpoint = 0x010a,
    set_watchpoint = 0x010b,
    clear_watchpoint = 0x010c,
    subscribe = 0x010d,
    unsubscribe = 0x010e,
    now = 0x010f,
    interrupt = 0x0110,
    set_run_budget = 0x0111,
    remove_point = 0x0112,
    plug = 0x0113,
    unplug = 0x0114,
    set_fault = 0x0115,
    clear_fault = 0x0116,
    advance = 0x0117,
    snapshot = 0x0118,
    restore = 0x0119,
    list_parts = 0x011a,
    set_camera_source = 0x011b,
    map = 0x011c,
    stack = 0x011d,
    rtc = 0x011e,
    input = 0x011f,
    backtrace = 0x0120,
    periph = 0x0121,
    folded = 0x0122,
    set_breakpoint_name = 0x0123,
    load_begin = 0x0124,
    load_chunk = 0x0125,
    load_end = 0x0126,
    board_parts = 0x0127,
    source_line = 0x0128,
    locals = 0x0129,
    locals_at = 0x012A,
    advance_async = 0x012B,
    seek = 0x012C,
    rcont = 0x012D,
    branch_list = 0x0130,
    branch_switch = 0x0131,
    branch_delete = 0x0132,
    branch_confirm_fork = 0x0133,
    branch_cancel_fork = 0x0134,
    branch_status = 0x0135,
    console_input = 0x0136,
    skip_bkpt = 0x0137,
    play = 0x0138,
    nav_query = 0x0139,
    marker_set = 0x013A,
    frame_status = 0x013B,
    diff = 0x013C,
};
pub const Topic = enum(u16) { stop = 0x0100, uart = 0x0101, speed = 0x0102, lcd_dirty = 0x0103, trace = 0x0104, session = 0x0105, transport = 0x0106 };
pub const Core = enum(u8) { cpu0, cpu1 };
pub const Register = enum(u8) { pc, sp, lr, r0, r1, r2, r3, r12, xpsr, primask, psp, r4, r5, r6, r7, r8, r9, r10, r11, msp, basepri, faultmask, control, fpscr, msplim, psplim, s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15, s16, s17, s18, s19, s20, s21, s22, s23, s24, s25, s26, s27, s28, s29, s30, s31, vpr };
pub const RunMode = enum(u8) { run, cont, step, next, finish };
pub const StopReason = enum(u8) { stepped, breakpoint, watchpoint, halt_requested, unit_break, unit_watch, count, core_fault, replay_failed };
pub const Access = enum(u8) { read, write, access };
pub const EventKind = enum(u8) { loaded, paused, stopped, register_written, memory_written, breakpoint_set, breakpoint_cleared, watchpoint_set, watchpoint_cleared, speed_changed, input_scheduled, fault_set, fault_cleared, plugged, unplugged, led_changed, module_loaded, module_unloaded, module_faulted, rtos_switch, rtos_idle, isr_enter, isr_leave };

pub const Load = struct {
    core: Core,
    image: []const u8,
    pub const max_len = .{ .image = max_payload };
};

/// The chunked load protocol (RA8EMU-1174): an image larger than one
/// payload streams in ordered chunks and commits with load_end; small
/// images keep the single Load wire format above.
pub const LoadBegin = struct { core: Core, total_len: u64, checksum: u32 };
pub const LoadChunk = struct {
    core: Core,
    offset: u64,
    bytes: []const u8,
    pub const max_len = .{ .bytes = max_payload };
};
pub const Run = struct { core: Core, mode: RunMode, budget: u64 };
pub const CoreOnly = struct { core: Core };
pub const CoreFrame = struct { core: Core, frame: u32 };
pub const SetSpeed = struct { core: Core, milli: u64 };
pub const ReadRegister = struct { core: Core, register: Register };
pub const WriteRegister = struct { core: Core, register: Register, value: u32 };
pub const ReadMemory = struct { core: Core, address: u32, length: u32 };
pub const Memory = struct {
    bytes: []const u8,
    pub const max_len = .{ .bytes = max_payload };
};
pub const WriteMemory = struct {
    core: Core,
    address: u32,
    bytes: []const u8,
    pub const max_len = .{ .bytes = max_payload };
};
pub const Point = struct { core: Core, address: u32 };
pub const PointId = struct { core: Core, id: u32 };
/// `break NAME`, resolved against the module table and then the image
/// (RA8EMU-1141); unknown names wait for their module to load.
pub const NamedBreak = struct {
    core: Core,
    name: []const u8,
    pub const max_len = .{ .name = 256 };
};
/// Where a named break landed: placed at `address`, or waiting with an id
/// from the table's pending numbering.
pub const NamedPoint = struct { id: u32, address: u32, deferred: u8 };
pub const Watch = struct { core: Core, first: u32, last: u32, access: Access };
/// Subscribing one core to one topic. For lcd_dirty, `rate` is the frames
/// per second the client wants (RA8EMU-822); zero is every frame.
pub const Subscription = struct { core: Core, topic: Topic, rate: u16 = 0 };
pub const Now = struct { core: Core };
pub const RunBudget = struct { core: Core, instructions: u64 };
pub const U64 = struct { value: u64 };
pub const U32 = struct { value: u32 };
pub const Bool = struct { value: u8 };
pub const Ack = struct { accepted: u8 };
/// `advance_async` accepted a long advance: the job is queued on the
/// transport and the completion arrives on the transport topic (slice 14).
pub const AdvanceQueued = struct { core: Core, from_ns: u64, target_ns: u64 };
/// A `seek` request (slice 17): the target as text in the design's own
/// language (section 2), validated by the queue door on the server.
pub const Seek = struct {
    target: []const u8,
    pub const max_len = .{ .target = 256 };
};
/// One transport report on the transport topic: the plane's state, and
/// when `finished` is 1 the advance the client asked `advance_async` for,
/// stopped where it got to. `phase` matches the transport's Phase order.
pub const TransportEvent = struct {
    epoch: u64,
    phase: u8,
    target_ns: u64,
    reached_ns: u64,
    slices: u64,
    finished: u8,
    core: Core,
    from_ns: u64,
    to_ns: u64,
    reason: StopReason,
    address: u32,
};
/// Run `core` until board time has moved `ns` virtual nanoseconds.
pub const Advance = struct { core: Core, ns: u64 };
/// Where an advance began and ended in virtual time, and how it stopped.
pub const Advanced = struct { core: Core, from_ns: u64, to_ns: u64, reason: StopReason, address: u32 };
/// A run file on the serving host, for snapshot and restore (RA8EMU-768).
pub const StatePath = struct {
    path: []const u8,
    pub const max_len = .{ .path = 4096 };
};
pub const Stopped = struct { core: Core, reason: StopReason, address: u32, detail: u32 };
pub const Uart = struct {
    core: Core,
    channel: u8,
    /// Board time when the run's last byte was written.
    virtual_ns: u64,
    bytes: []const u8,
    pub const max_len = .{ .bytes = 4096 };
};
pub const DirtyRect = struct {
    core: Core,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    virtual_ns: u64,
    pixels: []const u8,
    pub const max_len = .{ .pixels = 262144 };
};
/// A part spec in the CLI's own syntax: `MODEL@ENDPOINT` for plug,
/// `ENDPOINT` for unplug and clear_fault, `MODEL@ENDPOINT=MODE` for set_fault.
pub const PartSpec = struct {
    core: Core,
    text: []const u8,
    pub const max_len = .{ .text = 256 };
};
/// The fitted parts, one `MODEL@ENDPOINT` line each (RA8EMU-791).
pub const PartList = struct {
    text: []const u8,
    pub const max_len = .{ .text = 4096 };
};
/// The served board's front-panel parts (RA8EMU-1151): LED labels one per
/// line in the chip's led_changed order with one lamp colour per LED as 2
/// little-endian RGB565 bytes, switch labels one per line in the board's
/// switch order, and the panel profile the pre-frame slot fits (or no
/// panel). The GUI reads the board only through this, so the pane and the
/// CLI see the same parts.
pub const BoardParts = struct {
    /// The panel profile's stem; empty for no panel.
    panel: []const u8,
    panel_width: u32,
    panel_height: u32,
    led_names: []const u8,
    led_colors: []const u8,
    switch_names: []const u8,
    pub const max_len = .{ .panel = 64, .led_names = 256, .led_colors = 32, .switch_names = 256 };
};
pub const CameraSource = struct {
    text: []const u8,
    allow_webcam: u8 = 0,
    pub const max_len = .{ .text = 512 };
};
pub const MapAsk = struct { core: Core, json: u8 = 0 };
pub const MapText = struct {
    text: []const u8,
    pub const max_len = .{ .text = 65536 };
};
pub const PeriphAsk = struct {
    core: Core,
    json: u8 = 0,
    block: []const u8,
    pub const max_len = .{ .block = 32 };
};
/// The block list or one block's registers.
pub const PeriphText = struct {
    text: []const u8,
    pub const max_len = .{ .text = 65536 };
};
/// `thread` in a FoldedAsk that takes every thread.
pub const all_threads: u32 = 0xFFFF_FFFF;
/// A core's sampled call stacks folded over the virtual-time window
/// [from_ns, to_ns), for one thread or all of them (RA8EMU-833).
pub const FoldedAsk = struct { core: Core, thread: u32 = all_threads, from_ns: u64 = 0, to_ns: u64 = 0xFFFF_FFFF_FFFF_FFFF };
/// One `frames;... count` row per distinct stack, as --profile-folded.
pub const FoldedText = struct {
    text: []const u8,
    pub const max_len = .{ .text = 65536 };
};
/// A core's stack pointers, the lowest MSP and PSP since reset, and the
/// main stack reservation its image names (RA8EMU-816). With `has_stack`
/// 0 the image names none, and `base`, `size` and `overflow` are 0.
pub const StackReport = struct {
    core: Core,
    msp: u32,
    psp: u32,
    low_msp: u32,
    low_psp: u32,
    has_stack: u8,
    base: u32,
    size: u32,
    overflow: u32,
};
pub const Backtrace = @import("backtrace_wire.zig").Backtrace;
pub const StackFrame = @import("backtrace_wire.zig").StackFrame;
pub const backtrace_frames = @import("backtrace_wire.zig").backtrace_frames;
pub const frame_name_cap = @import("backtrace_wire.zig").frame_name_cap;
pub const frame_file_cap = @import("backtrace_wire.zig").frame_file_cap;
pub const frame_bytes = @import("backtrace_wire.zig").frame_bytes;
pub const backtrace_bytes = @import("backtrace_wire.zig").backtrace_bytes;
/// The source place of a core's pc (RA8EMU-1125): the file and line the pc
/// belongs to, looked up in the image's .debug_line. `found` is 0 and the
/// path empty when there is no image or the line table does not cover the
/// pc; the leaf reads the file's rows itself.
pub const SourceLine = struct {
    found: u8,
    /// The pc the answer is for, 0 when `found` is 0.
    pc: u32,
    line: u32,
    path: []const u8,
    pub const max_len = .{ .path = source_path_cap };
};
/// Characters of the answered source path.
pub const source_path_cap = 256;
/// A function's locals at a stopped core (RA8EMU-805): `count` rows in
/// `rows`, each a LocalRow as locals_wire.zig packs it.
pub const Locals = struct {
    core: Core,
    count: u8,
    rows: []const u8,
    pub const max_len = .{ .rows = locals_bytes };
};
/// One local of a function's locals. `where_kind` says where the local's
/// bytes live (where_kinds), with `where_a` and `where_b` carrying what
/// that kind needs; a type with no answer keeps `size` 0.
pub const LocalRow = struct {
    name: []const u8,
    type_name: []const u8,
    size: u32,
    where_kind: u8,
    where_a: u64,
    where_b: u64,
    pub const max_len = .{ .name = local_name_cap, .type_name = local_type_cap };
};
/// Where kinds a LocalRow's bytes live at.
pub const where_kinds = struct {
    pub const none: u8 = 0;
    /// At an offset (signed, in `where_a`) from the frame base.
    pub const frame: u8 = 1;
    /// In the register in `where_a` holding an address plus the signed
    /// offset in `where_b`.
    pub const register: u8 = 2;
    /// In the register in `where_a` outright.
    pub const in_register: u8 = 3;
    /// At the fixed address in `where_a`.
    pub const address: u8 = 4;
};
/// The most locals one answer carries, and the characters a local's name
/// and its type's name keep.
pub const locals_rows = 32;
pub const local_name_cap = 40;
pub const local_type_cap = 40;
/// One row's widest encoding plus the length byte before it.
pub const local_row_bytes = 1 + local_name_cap + 4 + local_type_cap + 4 + 4 + 1 + 8 + 8;
pub const locals_bytes = locals_rows * local_row_bytes;
/// The board's RTC calendar (RA8EMU-809). With `valid` 0 the counters hold
/// no date and every date field is 0; `running` is RCR2.START.
pub const RtcReport = struct {
    running: u8,
    valid: u8,
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};
/// One host input event for the board's input script (RA8EMU-810). A tap
/// uses x and y; a swipe goes from x, y to to_x, to_y over duration_ns; a
/// long press holds x, y for duration_ns; a button presses `button` (0 is
/// SW1, 1 is SW2) and the script releases it.
pub const InputKind = enum(u8) { tap, swipe, longpress, button };
pub const ScheduleInput = struct {
    core: Core,
    at_ns: u64,
    kind: InputKind,
    x: u16 = 0,
    y: u16 = 0,
    to_x: u16 = 0,
    to_y: u16 = 0,
    duration_ns: u64 = 0,
    button: u8 = 0,
};
pub const SessionEvent = struct { core: Core, kind: EventKind, address: u32 };
pub const TraceEvent = @import("trace_wire.zig").TraceEvent;
pub const Trace = @import("trace_wire.zig").Trace;

pub const branch_wire = @import("branch_wire.zig");
pub const BranchItem = branch_wire.BranchItem;
pub const BranchList = branch_wire.BranchList;
pub const BranchSwitch = branch_wire.BranchSwitch;
pub const BranchDelete = branch_wire.BranchDelete;
pub const BranchConfirmFork = branch_wire.BranchConfirmFork;
pub const BranchCancelFork = branch_wire.BranchCancelFork;
pub const ForkStatus = branch_wire.ForkStatus;
pub const nav_wire = @import("nav_wire.zig");
pub const Direction = nav_wire.Direction;
pub const PlayArgs = nav_wire.PlayArgs;
pub const NavQueryKind = nav_wire.NavQueryKind;
pub const NavQueryArgs = nav_wire.NavQueryArgs;
pub const NavQueryResult = nav_wire.NavQueryResult;
pub const MarkerSetArgs = nav_wire.MarkerSetArgs;
pub const FrameStatusResult = nav_wire.FrameStatusResult;
pub const diff_wire = @import("diff_wire.zig");
pub const DiffWire = diff_wire.DiffWire;
pub const DiffArgs = diff_wire.DiffArgs;
/// Calls a client can hold unanswered at once; a leaf with more reads than
/// this sends the rest as answers free slots.
pub const pending_slots = 32;
pub const Client = rpc.Client(pending_slots, max_payload);
pub const Error = rpc.Error;
pub fn encode(comptime T: type, value: T, out: []u8) ![]u8 {
    return rpc.codec.encode(T, value, out);
}
pub fn decode(comptime T: type, bytes: []const u8) !T {
    return rpc.codec.decode(T, bytes);
}
