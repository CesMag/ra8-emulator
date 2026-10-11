//! Session RPC messages carried by the shared RA8 wire protocol (RA8EMU-194).
const rpc = @import("ra8_rpc_wire");

pub const protocol_version: u16 = 1;
/// Bit 0: LCD dirty rectangles. Bit 1: plug, unplug and fault methods.
/// Bit 2: advance. Bit 3: snapshot and restore. Bit 6: stack. Bit 7: rtc.
/// Bit 8: input. Bit 9: backtrace. Bit 10: periph.
pub const capabilities: u32 = 0x0000_07FF;
pub const max_payload = 1_048_576;

/// Refusal codes this message set adds above the library's own.
pub const app_codes = struct {
    /// The Session refused the call; the error name went to stderr.
    pub const refused: u16 = 0x0100;
    /// The call named a core this session has no image for.
    pub const no_core: u16 = 0x0101;
    /// A read asked for more bytes than one reply carries.
    pub const too_long: u16 = 0x0102;
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
};
pub const Topic = enum(u16) { stop = 0x0100, uart = 0x0101, speed = 0x0102, lcd_dirty = 0x0103, trace = 0x0104, session = 0x0105 };
pub const Core = enum(u8) { cpu0, cpu1 };
pub const Register = enum(u8) { pc, sp, lr, r0, r1, r2, r3, r12, xpsr, primask, psp, r4, r5, r6, r7, r8, r9, r10, r11, msp, basepri, faultmask, control, fpscr, msplim, psplim, s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15, s16, s17, s18, s19, s20, s21, s22, s23, s24, s25, s26, s27, s28, s29, s30, s31, vpr };
pub const RunMode = enum(u8) { run, cont, step, next, finish };
pub const StopReason = enum(u8) { stepped, breakpoint, watchpoint, halt_requested, unit_break, unit_watch, count, core_fault };
pub const Access = enum(u8) { read, write, access };
pub const EventKind = enum(u8) { loaded, paused, stopped, register_written, memory_written, breakpoint_set, breakpoint_cleared, watchpoint_set, watchpoint_cleared, speed_changed, input_scheduled, fault_set, fault_cleared, plugged, unplugged, led_changed };

pub const Load = struct {
    core: Core,
    image: []const u8,
    pub const max_len = .{ .image = max_payload };
};
pub const Run = struct { core: Core, mode: RunMode, budget: u64 };
pub const CoreOnly = struct { core: Core };
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
pub const Watch = struct { core: Core, first: u32, last: u32, access: Access };
pub const Subscription = struct { core: Core, topic: Topic };
pub const Now = struct { core: Core };
pub const RunBudget = struct { core: Core, instructions: u64 };
pub const U64 = struct { value: u64 };
pub const U32 = struct { value: u32 };
pub const Bool = struct { value: u8 };
pub const Ack = struct { accepted: u8 };
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
/// A camera source in `--camera-source` syntax (RA8EMU-795); a webcam
/// opens only when `allow_webcam` is 1, the client's user having consented.
pub const CameraSource = struct {
    text: []const u8,
    allow_webcam: u8 = 0,
    pub const max_len = .{ .text = 512 };
};
/// Which core's image to map, and whether as JSON (1) or as the text
/// `--map` prints (0) (RA8EMU-794).
pub const MapAsk = struct { core: Core, json: u8 = 0 };
/// The memory map of the image the core last loaded.
pub const MapText = struct {
    text: []const u8,
    pub const max_len = .{ .text = 65536 };
};
/// The peripheral blocks a core's bus maps, or with `block` set the
/// registers of that block, as JSON (1) or text (0) (RA8EMU-818).
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
/// A core's call chain, innermost first (RA8EMU-1125): `count` frames in
/// `frames`, each a StackFrame as backtrace_wire.zig packs it.
pub const Backtrace = struct {
    core: Core,
    count: u8,
    frames: []const u8,
    pub const max_len = .{ .frames = backtrace_bytes };
};
/// One frame of a Backtrace. `interrupted` is 1 when an exception sits
/// between this frame and the one inside it; `line` is 0 and `file` empty
/// where the line table does not cover the frame, and `name` empty where
/// no symbol does.
pub const StackFrame = struct {
    pc: u32,
    interrupted: u8,
    offset: u32,
    line: u32,
    name: []const u8,
    file: []const u8,
    pub const max_len = .{ .name = frame_name_cap, .file = frame_file_cap };
};
/// The most frames a Backtrace carries, and the characters a frame's
/// function and file name keep.
pub const backtrace_frames = 32;
pub const frame_name_cap = 40;
pub const frame_file_cap = 32;
/// One frame's widest encoding plus the length byte before it.
pub const frame_bytes = 1 + 4 + 1 + 4 + 4 + 4 + frame_name_cap + 4 + frame_file_cap;
pub const backtrace_bytes = backtrace_frames * frame_bytes;
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
pub const Trace = struct {
    core: Core,
    bytes: []const u8,
    pub const max_len = .{ .bytes = 4096 };
};

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
