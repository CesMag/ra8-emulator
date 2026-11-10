/**
 * RA8 Emulator WebSocket RPC Type Definitions
 *
 * Implements complete type definitions matching src/interfaces/rpc/session/rpc.zig
 * and ADR 0010 (RA8EMU-A-29).
 */
export const PROTOCOL_MAGIC = 0x52384152; // 'RA8R' little-endian
export const PROTOCOL_VERSION = 1;
export const MAX_PAYLOAD = 1_048_576; // 1 MB
export const HEADER_BYTES = 6;
export const METRICS_REPORT_BYTES = 32;
/** Wire message kinds (Kind in envelope.zig) */
export var Kind;
(function (Kind) {
    Kind[Kind["Hello"] = 1] = "Hello";
    Kind[Kind["Request"] = 2] = "Request";
    Kind[Kind["Response"] = 3] = "Response";
    Kind[Kind["Event"] = 4] = "Event";
    Kind[Kind["Fault"] = 5] = "Fault";
})(Kind || (Kind = {}));
/** Error codes (Code in envelope.zig and app_codes in rpc.zig) */
export var ErrorCode;
(function (ErrorCode) {
    ErrorCode[ErrorCode["UnknownMethod"] = 1] = "UnknownMethod";
    ErrorCode[ErrorCode["BadArgs"] = 2] = "BadArgs";
    ErrorCode[ErrorCode["Failed"] = 3] = "Failed";
    ErrorCode[ErrorCode["VersionMismatch"] = 4] = "VersionMismatch";
    ErrorCode[ErrorCode["BadMagic"] = 5] = "BadMagic";
    ErrorCode[ErrorCode["NotReady"] = 6] = "NotReady";
    ErrorCode[ErrorCode["FirstApp"] = 256] = "FirstApp";
    ErrorCode[ErrorCode["AppRefused"] = 256] = "AppRefused";
    ErrorCode[ErrorCode["AppNoCore"] = 257] = "AppNoCore";
    ErrorCode[ErrorCode["AppTooLong"] = 258] = "AppTooLong";
    ErrorCode[ErrorCode["AppHistory"] = 259] = "AppHistory";
})(ErrorCode || (ErrorCode = {}));
/** All 59 Session RPC Opcodes (Method in rpc.zig) */
export var Method;
(function (Method) {
    Method[Method["Load"] = 256] = "Load";
    Method[Method["Run"] = 257] = "Run";
    Method[Method["Pause"] = 258] = "Pause";
    Method[Method["Step"] = 259] = "Step";
    Method[Method["SetSpeed"] = 260] = "SetSpeed";
    Method[Method["ReadRegister"] = 261] = "ReadRegister";
    Method[Method["WriteRegister"] = 262] = "WriteRegister";
    Method[Method["ReadMemory"] = 263] = "ReadMemory";
    Method[Method["WriteMemory"] = 264] = "WriteMemory";
    Method[Method["SetBreakpoint"] = 265] = "SetBreakpoint";
    Method[Method["ClearBreakpoint"] = 266] = "ClearBreakpoint";
    Method[Method["SetWatchpoint"] = 267] = "SetWatchpoint";
    Method[Method["ClearWatchpoint"] = 268] = "ClearWatchpoint";
    Method[Method["Subscribe"] = 269] = "Subscribe";
    Method[Method["Unsubscribe"] = 270] = "Unsubscribe";
    Method[Method["Now"] = 271] = "Now";
    Method[Method["Interrupt"] = 272] = "Interrupt";
    Method[Method["SetRunBudget"] = 273] = "SetRunBudget";
    Method[Method["RemovePoint"] = 274] = "RemovePoint";
    Method[Method["Plug"] = 275] = "Plug";
    Method[Method["Unplug"] = 276] = "Unplug";
    Method[Method["SetFault"] = 277] = "SetFault";
    Method[Method["ClearFault"] = 278] = "ClearFault";
    Method[Method["Advance"] = 279] = "Advance";
    Method[Method["Snapshot"] = 280] = "Snapshot";
    Method[Method["Restore"] = 281] = "Restore";
    Method[Method["ListParts"] = 282] = "ListParts";
    Method[Method["SetCameraSource"] = 283] = "SetCameraSource";
    Method[Method["Map"] = 284] = "Map";
    Method[Method["Stack"] = 285] = "Stack";
    Method[Method["Rtc"] = 286] = "Rtc";
    Method[Method["Input"] = 287] = "Input";
    Method[Method["Backtrace"] = 288] = "Backtrace";
    Method[Method["Periph"] = 289] = "Periph";
    Method[Method["Folded"] = 290] = "Folded";
    Method[Method["SetBreakpointName"] = 291] = "SetBreakpointName";
    Method[Method["LoadBegin"] = 292] = "LoadBegin";
    Method[Method["LoadChunk"] = 293] = "LoadChunk";
    Method[Method["LoadEnd"] = 294] = "LoadEnd";
    Method[Method["BoardParts"] = 295] = "BoardParts";
    Method[Method["SourceLine"] = 296] = "SourceLine";
    Method[Method["Locals"] = 297] = "Locals";
    Method[Method["LocalsAt"] = 298] = "LocalsAt";
    Method[Method["AdvanceAsync"] = 299] = "AdvanceAsync";
    Method[Method["Seek"] = 300] = "Seek";
    Method[Method["Rcont"] = 301] = "Rcont";
    Method[Method["Metrics"] = 302] = "Metrics";
    // 0x012F skipped
    Method[Method["BranchList"] = 304] = "BranchList";
    Method[Method["BranchSwitch"] = 305] = "BranchSwitch";
    Method[Method["BranchDelete"] = 306] = "BranchDelete";
    Method[Method["BranchConfirmFork"] = 307] = "BranchConfirmFork";
    Method[Method["BranchCancelFork"] = 308] = "BranchCancelFork";
    Method[Method["BranchStatus"] = 309] = "BranchStatus";
    Method[Method["ConsoleInput"] = 310] = "ConsoleInput";
    Method[Method["SkipBkpt"] = 311] = "SkipBkpt";
    Method[Method["Play"] = 312] = "Play";
    Method[Method["NavQuery"] = 313] = "NavQuery";
    Method[Method["MarkerSet"] = 314] = "MarkerSet";
    Method[Method["FrameStatus"] = 315] = "FrameStatus";
    Method[Method["Diff"] = 316] = "Diff";
})(Method || (Method = {}));
/** Opcode is an alias for Method */
export { Method as Opcode };
/** All 7 Event Topics (Topic in rpc.zig) */
export var Topic;
(function (Topic) {
    Topic[Topic["Stop"] = 256] = "Stop";
    Topic[Topic["Uart"] = 257] = "Uart";
    Topic[Topic["Speed"] = 258] = "Speed";
    Topic[Topic["LcdDirty"] = 259] = "LcdDirty";
    Topic[Topic["Trace"] = 260] = "Trace";
    Topic[Topic["Session"] = 261] = "Session";
    Topic[Topic["Transport"] = 262] = "Transport";
})(Topic || (Topic = {}));
/** Target CPU core (Core in rpc.zig) */
export var Core;
(function (Core) {
    Core[Core["Cpu0"] = 0] = "Cpu0";
    Core[Core["Cpu1"] = 1] = "Cpu1";
})(Core || (Core = {}));
/** ARM Cortex-M Registers (Register in rpc.zig) */
export var Register;
(function (Register) {
    Register[Register["Pc"] = 0] = "Pc";
    Register[Register["Sp"] = 1] = "Sp";
    Register[Register["Lr"] = 2] = "Lr";
    Register[Register["R0"] = 3] = "R0";
    Register[Register["R1"] = 4] = "R1";
    Register[Register["R2"] = 5] = "R2";
    Register[Register["R3"] = 6] = "R3";
    Register[Register["R12"] = 7] = "R12";
    Register[Register["Xpsr"] = 8] = "Xpsr";
    Register[Register["Primask"] = 9] = "Primask";
    Register[Register["Psp"] = 10] = "Psp";
    Register[Register["R4"] = 11] = "R4";
    Register[Register["R5"] = 12] = "R5";
    Register[Register["R6"] = 13] = "R6";
    Register[Register["R7"] = 14] = "R7";
    Register[Register["R8"] = 15] = "R8";
    Register[Register["R9"] = 16] = "R9";
    Register[Register["R10"] = 17] = "R10";
    Register[Register["R11"] = 18] = "R11";
    Register[Register["Msp"] = 19] = "Msp";
    Register[Register["Basepri"] = 20] = "Basepri";
    Register[Register["Faultmask"] = 21] = "Faultmask";
    Register[Register["Control"] = 22] = "Control";
    Register[Register["Fpscr"] = 23] = "Fpscr";
    Register[Register["Msplim"] = 24] = "Msplim";
    Register[Register["Psplim"] = 25] = "Psplim";
    Register[Register["S0"] = 26] = "S0";
    Register[Register["S1"] = 27] = "S1";
    Register[Register["S2"] = 28] = "S2";
    Register[Register["S3"] = 29] = "S3";
    Register[Register["S4"] = 30] = "S4";
    Register[Register["S5"] = 31] = "S5";
    Register[Register["S6"] = 32] = "S6";
    Register[Register["S7"] = 33] = "S7";
    Register[Register["S8"] = 34] = "S8";
    Register[Register["S9"] = 35] = "S9";
    Register[Register["S10"] = 36] = "S10";
    Register[Register["S11"] = 37] = "S11";
    Register[Register["S12"] = 38] = "S12";
    Register[Register["S13"] = 39] = "S13";
    Register[Register["S14"] = 40] = "S14";
    Register[Register["S15"] = 41] = "S15";
    Register[Register["S16"] = 42] = "S16";
    Register[Register["S17"] = 43] = "S17";
    Register[Register["S18"] = 44] = "S18";
    Register[Register["S19"] = 45] = "S19";
    Register[Register["S20"] = 46] = "S20";
    Register[Register["S21"] = 47] = "S21";
    Register[Register["S22"] = 48] = "S22";
    Register[Register["S23"] = 49] = "S23";
    Register[Register["S24"] = 50] = "S24";
    Register[Register["S25"] = 51] = "S25";
    Register[Register["S26"] = 52] = "S26";
    Register[Register["S27"] = 53] = "S27";
    Register[Register["S28"] = 54] = "S28";
    Register[Register["S29"] = 55] = "S29";
    Register[Register["S30"] = 56] = "S30";
    Register[Register["S31"] = 57] = "S31";
    Register[Register["Vpr"] = 58] = "Vpr";
})(Register || (Register = {}));
/** Run mode (RunMode in rpc.zig) */
export var RunMode;
(function (RunMode) {
    RunMode[RunMode["Run"] = 0] = "Run";
    RunMode[RunMode["Cont"] = 1] = "Cont";
    RunMode[RunMode["Step"] = 2] = "Step";
    RunMode[RunMode["Next"] = 3] = "Next";
    RunMode[RunMode["Finish"] = 4] = "Finish";
})(RunMode || (RunMode = {}));
/** Stop reason (StopReason in rpc.zig) */
export var StopReason;
(function (StopReason) {
    StopReason[StopReason["Stepped"] = 0] = "Stepped";
    StopReason[StopReason["Breakpoint"] = 1] = "Breakpoint";
    StopReason[StopReason["Watchpoint"] = 2] = "Watchpoint";
    StopReason[StopReason["HaltRequested"] = 3] = "HaltRequested";
    StopReason[StopReason["UnitBreak"] = 4] = "UnitBreak";
    StopReason[StopReason["UnitWatch"] = 5] = "UnitWatch";
    StopReason[StopReason["Count"] = 6] = "Count";
    StopReason[StopReason["CoreFault"] = 7] = "CoreFault";
    StopReason[StopReason["ReplayFailed"] = 8] = "ReplayFailed";
})(StopReason || (StopReason = {}));
/** Memory access type (Access in rpc.zig) */
export var Access;
(function (Access) {
    Access[Access["Read"] = 0] = "Read";
    Access[Access["Write"] = 1] = "Write";
    Access[Access["Access"] = 2] = "Access";
})(Access || (Access = {}));
/** Session event kind (EventKind in rpc.zig) */
export var EventKind;
(function (EventKind) {
    EventKind[EventKind["Loaded"] = 0] = "Loaded";
    EventKind[EventKind["Paused"] = 1] = "Paused";
    EventKind[EventKind["Stopped"] = 2] = "Stopped";
    EventKind[EventKind["RegisterWritten"] = 3] = "RegisterWritten";
    EventKind[EventKind["MemoryWritten"] = 4] = "MemoryWritten";
    EventKind[EventKind["BreakpointSet"] = 5] = "BreakpointSet";
    EventKind[EventKind["BreakpointCleared"] = 6] = "BreakpointCleared";
    EventKind[EventKind["WatchpointSet"] = 7] = "WatchpointSet";
    EventKind[EventKind["WatchpointCleared"] = 8] = "WatchpointCleared";
    EventKind[EventKind["SpeedChanged"] = 9] = "SpeedChanged";
    EventKind[EventKind["InputScheduled"] = 10] = "InputScheduled";
    EventKind[EventKind["FaultSet"] = 11] = "FaultSet";
    EventKind[EventKind["FaultCleared"] = 12] = "FaultCleared";
    EventKind[EventKind["Plugged"] = 13] = "Plugged";
    EventKind[EventKind["Unplugged"] = 14] = "Unplugged";
    EventKind[EventKind["LedChanged"] = 15] = "LedChanged";
    EventKind[EventKind["ModuleLoaded"] = 16] = "ModuleLoaded";
    EventKind[EventKind["ModuleUnloaded"] = 17] = "ModuleUnloaded";
    EventKind[EventKind["ModuleFaulted"] = 18] = "ModuleFaulted";
    EventKind[EventKind["RtosSwitch"] = 19] = "RtosSwitch";
    EventKind[EventKind["RtosIdle"] = 20] = "RtosIdle";
    EventKind[EventKind["IsrEnter"] = 21] = "IsrEnter";
    EventKind[EventKind["IsrLeave"] = 22] = "IsrLeave";
})(EventKind || (EventKind = {}));
/** Input kind (InputKind in rpc.zig) */
export var InputKind;
(function (InputKind) {
    InputKind[InputKind["Tap"] = 0] = "Tap";
    InputKind[InputKind["Swipe"] = 1] = "Swipe";
    InputKind[InputKind["LongPress"] = 2] = "LongPress";
    InputKind[InputKind["Button"] = 3] = "Button";
})(InputKind || (InputKind = {}));
/** Result tag in response envelope (ResultTag in envelope.zig) */
export var ResultTag;
(function (ResultTag) {
    ResultTag[ResultTag["Ok"] = 0] = "Ok";
    ResultTag[ResultTag["Err"] = 1] = "Err";
})(ResultTag || (ResultTag = {}));
//# sourceMappingURL=types.js.map