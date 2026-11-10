/**
 * RA8 Emulator WebSocket RPC Type Definitions
 *
 * Implements complete type definitions matching src/interfaces/rpc/session/rpc.zig
 * and ADR 0010 (RA8EMU-A-29).
 */
export declare const PROTOCOL_MAGIC = 1379418450;
export declare const PROTOCOL_VERSION = 1;
export declare const MAX_PAYLOAD = 1048576;
export declare const HEADER_BYTES = 6;
export declare const METRICS_REPORT_BYTES = 32;
/** Wire message kinds (Kind in envelope.zig) */
export declare enum Kind {
    Hello = 1,
    Request = 2,
    Response = 3,
    Event = 4,
    Fault = 5
}
/** Error codes (Code in envelope.zig and app_codes in rpc.zig) */
export declare enum ErrorCode {
    UnknownMethod = 1,
    BadArgs = 2,
    Failed = 3,
    VersionMismatch = 4,
    BadMagic = 5,
    NotReady = 6,
    FirstApp = 256,
    AppRefused = 256,
    AppNoCore = 257,
    AppTooLong = 258,
    AppHistory = 259
}
/** All 61 Session RPC Opcodes (Method in rpc.zig) */
export declare enum Method {
    Load = 256,
    Run = 257,
    Pause = 258,
    Step = 259,
    SetSpeed = 260,
    ReadRegister = 261,
    WriteRegister = 262,
    ReadMemory = 263,
    WriteMemory = 264,
    SetBreakpoint = 265,
    ClearBreakpoint = 266,
    SetWatchpoint = 267,
    ClearWatchpoint = 268,
    Subscribe = 269,
    Unsubscribe = 270,
    Now = 271,
    Interrupt = 272,
    SetRunBudget = 273,
    RemovePoint = 274,
    Plug = 275,
    Unplug = 276,
    SetFault = 277,
    ClearFault = 278,
    Advance = 279,
    Snapshot = 280,
    Restore = 281,
    ListParts = 282,
    SetCameraSource = 283,
    Map = 284,
    Stack = 285,
    Rtc = 286,
    Input = 287,
    Backtrace = 288,
    Periph = 289,
    Folded = 290,
    SetBreakpointName = 291,
    LoadBegin = 292,
    LoadChunk = 293,
    LoadEnd = 294,
    BoardParts = 295,
    SourceLine = 296,
    Locals = 297,
    LocalsAt = 298,
    AdvanceAsync = 299,
    Seek = 300,
    Rcont = 301,
    Metrics = 302,
    BranchList = 304,
    BranchSwitch = 305,
    BranchDelete = 306,
    BranchConfirmFork = 307,
    BranchCancelFork = 308,
    BranchStatus = 309,
    ConsoleInput = 310,
    SkipBkpt = 311,
    Play = 312,
    NavQuery = 313,
    MarkerSet = 314,
    FrameStatus = 315,
    Diff = 316,
    Disasm = 317
}
/** Opcode is an alias for Method */
export { Method as Opcode };
/** All 7 Event Topics (Topic in rpc.zig) */
export declare enum Topic {
    Stop = 256,
    Uart = 257,
    Speed = 258,
    LcdDirty = 259,
    Trace = 260,
    Session = 261,
    Transport = 262
}
/** Target CPU core (Core in rpc.zig) */
export declare enum Core {
    Cpu0 = 0,
    Cpu1 = 1
}
/** ARM Cortex-M Registers (Register in rpc.zig) */
export declare enum Register {
    Pc = 0,
    Sp = 1,
    Lr = 2,
    R0 = 3,
    R1 = 4,
    R2 = 5,
    R3 = 6,
    R12 = 7,
    Xpsr = 8,
    Primask = 9,
    Psp = 10,
    R4 = 11,
    R5 = 12,
    R6 = 13,
    R7 = 14,
    R8 = 15,
    R9 = 16,
    R10 = 17,
    R11 = 18,
    Msp = 19,
    Basepri = 20,
    Faultmask = 21,
    Control = 22,
    Fpscr = 23,
    Msplim = 24,
    Psplim = 25,
    S0 = 26,
    S1 = 27,
    S2 = 28,
    S3 = 29,
    S4 = 30,
    S5 = 31,
    S6 = 32,
    S7 = 33,
    S8 = 34,
    S9 = 35,
    S10 = 36,
    S11 = 37,
    S12 = 38,
    S13 = 39,
    S14 = 40,
    S15 = 41,
    S16 = 42,
    S17 = 43,
    S18 = 44,
    S19 = 45,
    S20 = 46,
    S21 = 47,
    S22 = 48,
    S23 = 49,
    S24 = 50,
    S25 = 51,
    S26 = 52,
    S27 = 53,
    S28 = 54,
    S29 = 55,
    S30 = 56,
    S31 = 57,
    Vpr = 58
}
/** Run mode (RunMode in rpc.zig) */
export declare enum RunMode {
    Run = 0,
    Cont = 1,
    Step = 2,
    Next = 3,
    Finish = 4
}
/** Stop reason (StopReason in rpc.zig) */
export declare enum StopReason {
    Stepped = 0,
    Breakpoint = 1,
    Watchpoint = 2,
    HaltRequested = 3,
    UnitBreak = 4,
    UnitWatch = 5,
    Count = 6,
    CoreFault = 7,
    ReplayFailed = 8
}
/** Memory access type (Access in rpc.zig) */
export declare enum Access {
    Read = 0,
    Write = 1,
    Access = 2
}
/** Session event kind (EventKind in rpc.zig) */
export declare enum EventKind {
    Loaded = 0,
    Paused = 1,
    Stopped = 2,
    RegisterWritten = 3,
    MemoryWritten = 4,
    BreakpointSet = 5,
    BreakpointCleared = 6,
    WatchpointSet = 7,
    WatchpointCleared = 8,
    SpeedChanged = 9,
    InputScheduled = 10,
    FaultSet = 11,
    FaultCleared = 12,
    Plugged = 13,
    Unplugged = 14,
    LedChanged = 15,
    ModuleLoaded = 16,
    ModuleUnloaded = 17,
    ModuleFaulted = 18,
    RtosSwitch = 19,
    RtosIdle = 20,
    IsrEnter = 21,
    IsrLeave = 22
}
/** Input kind (InputKind in rpc.zig) */
export declare enum InputKind {
    Tap = 0,
    Swipe = 1,
    LongPress = 2,
    Button = 3
}
/** Result tag in response envelope (ResultTag in envelope.zig) */
export declare enum ResultTag {
    Ok = 0,
    Err = 1
}
/** 6-byte Frame Header */
export interface RpcHeader {
    length: number;
    kind: Kind;
}
/** Hello handshake frame */
export interface Hello {
    magic: number;
    version: number;
    caps: number;
}
/** Fault frame */
export interface Fault {
    code: ErrorCode | number;
    version: number;
}
/** Request envelope */
export interface RpcRequestEnvelope {
    id: number;
    method: Method | number;
    args: Uint8Array;
}
/** Response envelope */
export interface RpcResponseEnvelope {
    id: number;
    ok: boolean;
    code?: ErrorCode | number;
    payload: Uint8Array;
}
/** Event envelope */
export interface RpcEventEnvelope {
    topic: Topic | number;
    payload: Uint8Array;
}
/** 32-byte host and guest device metrics wire struct (metrics_wire.zig) */
export interface MetricsReport {
    hostCpuPercent: number;
    hostRssMb: number;
    hostThreads: number;
    cpu0LoadPercent: number;
    cpu0Pinned: number;
    cpu0RamUsedBytes: number;
    cpu0RamTotalBytes: number;
    cpu1LoadPercent: number;
    cpu1Pinned: number;
    cpu1RamUsedBytes: number;
    cpu1RamTotalBytes: number;
}
/** Dirty rectangle for LCD display streaming (DirtyRect in rpc.zig) */
export interface DirtyRect {
    core: Core;
    x: number;
    y: number;
    width: number;
    height: number;
    virtualNs: bigint;
    pixels: Uint8Array;
}
/** Stopped event notification (Stopped in rpc.zig) */
export interface Stopped {
    core: Core;
    reason: StopReason;
    address: number;
    detail: number;
}
/** UART serial output notification (Uart in rpc.zig) */
export interface UartEvent {
    core: Core;
    channel: number;
    virtualNs: bigint;
    bytes: Uint8Array;
}
/** General session event notification (SessionEvent in rpc.zig) */
export interface SessionEvent {
    core: Core;
    kind: EventKind;
    address: number;
}
/** Transport progress and completion event (TransportEvent in rpc.zig) */
export interface TransportEvent {
    epoch: bigint;
    phase: number;
    targetNs: bigint;
    reachedNs: bigint;
    slices: bigint;
    finished: number;
    core: Core;
    fromNs: bigint;
    toNs: bigint;
    reason: StopReason;
    address: number;
}
/** Method payload arguments */
export interface CoreOnlyArgs {
    core: Core;
}
export interface RunArgs {
    core: Core;
    mode: RunMode;
    budget: bigint;
}
export interface ReadRegisterArgs {
    core: Core;
    register: Register;
}
export interface WriteRegisterArgs {
    core: Core;
    register: Register;
    value: number;
}
export interface ReadMemoryArgs {
    core: Core;
    address: number;
    length: number;
}
export interface WriteMemoryArgs {
    core: Core;
    address: number;
    bytes: Uint8Array;
}
export interface SetBreakpointArgs {
    core: Core;
    address: number;
}
export interface SetNamedBreakpointArgs {
    core: Core;
    name: string;
}
export interface PointIdArgs {
    core: Core;
    id: number;
}
export interface SetWatchpointArgs {
    core: Core;
    first: number;
    last: number;
    access: Access;
}
export interface SubscriptionArgs {
    core: Core;
    topic: Topic;
    rate?: number;
}
export interface AdvanceArgs {
    core: Core;
    ns: bigint;
}
export interface AdvanceQueued {
    core: Core;
    fromNs: bigint;
    targetNs: bigint;
}
export interface SeekArgs {
    target: string;
}
export interface PartSpecArgs {
    core: Core;
    text: string;
}
export interface ScheduleInputArgs {
    core: Core;
    atNs: bigint;
    kind: InputKind;
    x?: number;
    y?: number;
    toX?: number;
    toY?: number;
    durationNs?: bigint;
    button?: number;
}
export interface Ack {
    accepted: number;
}
export interface BoardParts {
    panel: string;
    panelWidth: number;
    panelHeight: number;
    ledNames: string[];
    ledColors: number[];
    switchNames: string[];
}
export interface StackFrame {
    pc: number;
    interrupted: number;
    offset: number;
    line: number;
    name: string;
    file: string;
}
export interface Backtrace {
    core: Core;
    count: number;
    frames: StackFrame[];
}
/** Authoritative backend disassembly request (DisasmAsk in disasm_wire.zig) */
export interface DisasmAsk {
    core: Core;
    address?: number;
    count?: number;
    usePc?: boolean;
}
/** Single decoded instruction row from Zig backend (DisasmRow in disasm_wire.zig) */
export interface DisasmRow {
    address: number;
    size: number;
    decoded: boolean;
    raw: Uint8Array;
    text: string;
    symbol: string;
}
/** Authoritative backend disassembly reply (DisasmReply in disasm_wire.zig) */
export interface DisasmReply {
    core: Core;
    pc: number;
    count: number;
    rows: DisasmRow[];
}
/** Stack watermark and overflow report (StackReport in rpc.zig) */
export interface StackReport {
    core: Core;
    msp: number;
    psp: number;
    lowMsp: number;
    lowPsp: number;
    hasStack: boolean;
    base: number;
    size: number;
    overflow: number;
}
/** RTOS and exception trace event on Topic.Trace (TraceEvent in trace_wire.zig) */
export interface TraceEvent {
    core: Core;
    kind: EventKind;
    virtualNs: bigint;
    thread: number;
    exception: number;
    name: string;
}
/** Why a time-travel history branch forked (ForkReason in record.zig) */
export declare enum ForkReason {
    Base = 0,
    Writes = 1,
    Taps = 2,
    Buttons = 3,
    Keystrokes = 4,
    PlugUnplugFault = 5,
    CameraChange = 6,
    SkipBkpt = 7,
    Load = 8
}
/** One branch item in the execution DAG (BranchItem in branch_wire.zig) */
export interface BranchItem {
    id: number;
    parent: number;
    forkR: bigint;
    recordedEndR: bigint;
    childCount: number;
    reason: ForkReason;
    flags: number;
    isLive: boolean;
    isKept: boolean;
    isPinned: boolean;
}
/** Pending fork status (ForkStatus in branch_wire.zig) */
export interface ForkStatus {
    pending: boolean;
    reason: ForkReason;
    branch: number;
    r: bigint;
}
/** Playback direction (Direction in nav_wire.zig) */
export declare enum Direction {
    Fwd = 0,
    Back = 1
}
/** Playback arguments (PlayArgs in nav_wire.zig) */
export interface PlayArgs {
    dir: Direction;
    speedMilli?: bigint;
}
/** Navigation query kind (NavQueryKind in nav_wire.zig) */
export declare enum NavQueryKind {
    Frame = 0,
    Iteration = 1,
    Marker = 2,
    Rtos = 3,
    Isr = 4
}
/** Navigation query arguments (NavQueryArgs in nav_wire.zig) */
export interface NavQueryArgs {
    kind: NavQueryKind;
    index?: bigint;
    name?: string;
}
/** Navigation query reply (NavQueryResult in nav_wire.zig) */
export interface NavQueryResult {
    found: boolean;
    branch: number;
    r: bigint;
    phase: number;
    o: number;
    gap: number;
    count: bigint;
    slots: bigint;
    virtualNs: bigint;
}
/** Rewind and frame pipeline status (FrameStatusResult in nav_wire.zig) */
export interface FrameStatusResult {
    ramBytes: bigint;
    diskBytes: bigint;
    queueBytes: bigint;
    frames: bigint;
    decodedSegments: bigint;
}
/** Position of one side of a state diff (Side in diff_wire.zig) */
export interface DiffSide {
    branch: number;
    r: bigint;
}
export interface DiffRegItem {
    core: Core;
    name: string;
    valA: number;
    valB: number;
}
export interface DiffPageItem {
    space: number;
    pageIndex: number;
    address: number;
    hasA: boolean;
    objA: Uint8Array;
    hasB: boolean;
    objB: Uint8Array;
}
export interface DiffPeriphItem {
    unit: string;
    offset: number;
    oldVal: number;
    newVal: number;
    changedBytes: number;
}
/** Decoded state diff between two execution points (DecodedDiff in diff_wire.zig) */
export interface DecodedDiff {
    frames: number;
    a: DiffSide;
    b: DiffSide;
    regs: DiffRegItem[];
    pages: DiffPageItem[];
    periphs: DiffPeriphItem[];
}
/** Symbolic breakpoint placement result (NamedPoint in rpc.zig) */
export interface NamedPointResult {
    id: number;
    address: number;
    deferred: boolean;
}
/** Virtual-time advance completion reply (Advanced in rpc.zig) */
export interface AdvancedResult {
    core: Core;
    fromNs: bigint;
    toNs: bigint;
    reason: StopReason;
    address: number;
}
/** DWARF source location for a core's PC (SourceLine in rpc.zig) */
export interface SourceLineResult {
    found: boolean;
    pc: number;
    line: number;
    path: string;
}
/** Storage location kind for a DWARF local variable (where_kinds in locals_wire.zig) */
export declare enum LocalWhereKind {
    None = 0,
    Frame = 1,
    RegisterIndirect = 2,
    InRegister = 3,
    Address = 4
}
/** Single DWARF local variable entry (LocalRow in locals_wire.zig) */
export interface LocalVariable {
    name: string;
    typeName: string;
    size: number;
    whereKind: LocalWhereKind;
    whereA: bigint;
    whereB: bigint;
}
/** Function locals reply for a halted core/frame (Locals in locals_wire.zig) */
export interface LocalsResult {
    core: Core;
    count: number;
    locals: LocalVariable[];
}
/** Parsed ELF32 symbol entry for instant client-side symbol search and autocomplete */
export interface ElfSymbol {
    name: string;
    address: number;
    size: number;
    kind: "func" | "object" | "other";
}
//# sourceMappingURL=types.d.ts.map