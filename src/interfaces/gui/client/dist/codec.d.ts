/**
 * RA8 Binary Wire Protocol Codec
 *
 * Implements high-performance binary encoding and decoding using DataView
 * adhering to ra8_rpc_wire specifications and zero-padding struct layout.
 */
import { Kind, ErrorCode, Method, Topic, Core, Register, RunMode, RpcHeader, RpcRequestEnvelope, RpcResponseEnvelope, RpcEventEnvelope, Hello, Fault, MetricsReport, DirtyRect, Stopped, UartEvent, Ack, SessionEvent, ScheduleInputArgs, BoardParts, Backtrace, DisasmAsk, DisasmReply, StackReport, TraceEvent, TransportEvent, BranchItem, ForkStatus, PlayArgs, NavQueryArgs, NavQueryResult, FrameStatusResult, DecodedDiff, Access, NamedPointResult, AdvancedResult, SourceLineResult, LocalsResult } from "./types.js";
/** Encode the 6-byte frame header */
export declare function encodeHeader(length: number, kind: Kind | number): Uint8Array;
/** Decode the 6-byte frame header */
export declare function decodeHeader(data: Uint8Array): RpcHeader;
/** Wrap a payload into a framed binary packet with the 6-byte header */
export declare function encodeFrame(kind: Kind | number, payload: Uint8Array): Uint8Array;
export interface SplitResult {
    frames: Array<{
        kind: Kind;
        payload: Uint8Array;
    }>;
    remainder: Uint8Array;
}
/** Parse and split contiguous frames from an incoming stream buffer */
export declare function splitFrames(buffer: Uint8Array, maxPayload?: number): SplitResult;
/** Encode Hello payload (10 bytes: magic u32, version u16, caps u32) */
export declare function encodeHello(caps: number, magic?: number, version?: number): Uint8Array;
/** Decode Hello payload */
export declare function decodeHello(payload: Uint8Array): Hello;
/** Encode Fault payload (4 bytes: code u16, version u16) */
export declare function encodeFault(code: ErrorCode | number, version?: number): Uint8Array;
/** Decode Fault payload */
export declare function decodeFault(payload: Uint8Array): Fault;
/** Encode Request envelope */
export declare function encodeRequest(id: number, method: Method | number, args?: Uint8Array): Uint8Array;
/** Decode Request envelope */
export declare function decodeRequest(payload: Uint8Array): RpcRequestEnvelope;
/** Encode Response envelope */
export declare function encodeResponse(id: number, ok: boolean, payloadOrCode: Uint8Array | number): Uint8Array;
/** Decode Response envelope */
export declare function decodeResponse(payload: Uint8Array): RpcResponseEnvelope;
/** Encode Event envelope */
export declare function encodeEvent(topic: Topic | number, payload: Uint8Array): Uint8Array;
/** Decode Event envelope */
export declare function decodeEvent(payload: Uint8Array): RpcEventEnvelope;
/** Encode CoreOnly argument (1 byte) */
export declare function encodeCoreOnly(core: Core): Uint8Array;
/** Decode CoreOnly argument */
export declare function decodeCoreOnly(data: Uint8Array): Core;
/** Encode Run argument (10 bytes: core u8, mode u8, budget u64 LE) */
export declare function encodeRun(core: Core, mode: RunMode, budget?: bigint): Uint8Array;
/** Encode ReadRegister argument (2 bytes: core u8, register u8) */
export declare function encodeReadRegister(core: Core, register: Register): Uint8Array;
/** Encode WriteRegister argument (6 bytes: core u8, register u8, value u32 LE) */
export declare function encodeWriteRegister(core: Core, register: Register, value: number): Uint8Array;
/** Encode ReadMemory argument (9 bytes: core u8, address u32 LE, length u32 LE) */
export declare function encodeReadMemory(core: Core, address: number, length: number): Uint8Array;
/** Decode Memory result ([]const u8: u32 len LE + bytes) */
export declare function decodeMemory(data: Uint8Array): Uint8Array;
/** Encode WriteMemory argument (1 + 4 + 4 + bytes.length) */
export declare function encodeWriteMemory(core: Core, address: number, bytes: Uint8Array): Uint8Array;
/** Encode Subscription argument (5 bytes: core u8, topic u16 LE, rate u16 LE) */
export declare function encodeSubscription(core: Core, topic: Topic, rate?: number): Uint8Array;
/** Encode SetBreakpoint / ClearBreakpoint argument (5 bytes: core u8, address u32 LE) */
export declare function encodePoint(core: Core, address: number): Uint8Array;
/** Encode Advance argument (9 bytes: core u8, ns u64 LE) */
export declare function encodeAdvance(core: Core, ns: bigint): Uint8Array;
/** Decode U32 result (4 bytes) */
export declare function decodeU32(data: Uint8Array): number;
/** Encode U32 */
export declare function encodeU32(value: number): Uint8Array;
/** Decode Ack result (1 byte) */
export declare function decodeAck(data: Uint8Array): Ack;
/** Decode Stopped event (10 bytes: core u8, reason u8, address u32 LE, detail u32 LE) */
export declare function decodeStopped(data: Uint8Array): Stopped;
/** Decode Uart event (1 + 1 + 8 + 4 + bytes) */
export declare function decodeUart(data: Uint8Array): UartEvent;
/** Decode MetricsReport (32-byte layout matching metrics_wire.zig) */
export declare function decodeMetricsReport(data: Uint8Array): MetricsReport;
/** Encode MetricsReport (32 bytes) */
export declare function encodeMetricsReport(report: MetricsReport): Uint8Array;
/** Decode DirtyRect (21 bytes header + pixel data matching rpc.zig) */
export declare function decodeDirtyRect(data: Uint8Array): DirtyRect;
/** Encode DirtyRect */
export declare function encodeDirtyRect(rect: DirtyRect): Uint8Array;
/** Encode SetSpeed argument (9 bytes: core u8, milli u64 LE) */
export declare function encodeSetSpeed(core: Core, milli: bigint | number): Uint8Array;
/** Encode ScheduleInput argument (27 bytes) */
export declare function encodeScheduleInput(args: ScheduleInputArgs): Uint8Array;
/** Encode ConsoleInput argument (1 + 4 + bytes.length) */
export declare function encodeConsoleInput(core: Core, bytes: Uint8Array): Uint8Array;
/** Decode SessionEvent (6 bytes: core u8, kind u8, address u32 LE) */
export declare function decodeSessionEvent(data: Uint8Array): SessionEvent;
/** Decode BoardParts reply */
export declare function decodeBoardParts(data: Uint8Array): BoardParts;
/** Decode Backtrace reply */
export declare function decodeBacktrace(data: Uint8Array): Backtrace;
/** Decode U64 result (8 bytes) */
export declare function decodeU64(data: Uint8Array): bigint;
/** Encode PointId argument (5 bytes: core u8, id u32 LE) */
export declare function encodePointId(core: Core, id: number): Uint8Array;
/** Encode DisasmAsk argument (7 bytes: core u8, address u32 LE, count u8, use_pc u8) */
export declare function encodeDisasmAsk(args: DisasmAsk): Uint8Array;
/** Decode DisasmReply from Method.Disasm (0x013D) */
export declare function decodeDisasmReply(data: Uint8Array): DisasmReply;
/** Decode StackReport (30 bytes) */
export declare function decodeStackReport(data: Uint8Array): StackReport;
/** Decode single UTF-8 slice reply (PartList, PeriphText, MapText, FoldedText) */
export declare function decodeTextSlice(data: Uint8Array): string;
/** Encode PeriphAsk (core u8, json u8, block []const u8) */
export declare function encodePeriphAsk(core: Core, block?: string, json?: boolean): Uint8Array;
/** Encode FoldedAsk (21 bytes: core u8, thread u32, from_ns u64, to_ns u64) */
export declare function encodeFoldedAsk(core: Core, thread?: number, fromNs?: bigint, toNs?: bigint): Uint8Array;
/** Decode TraceEvent on Topic.Trace */
export declare function decodeTraceEvent(data: Uint8Array): TraceEvent;
/** Decode TransportEvent on Topic.Transport (56 bytes) */
export declare function decodeTransportEvent(data: Uint8Array): TransportEvent;
/** Decode BranchList reply from Method.BranchList (0x0130) */
export declare function decodeBranchList(data: Uint8Array): BranchItem[];
/** Encode BranchSwitch (4 bytes: branch u32 LE) */
export declare function encodeBranchSwitch(branch: number): Uint8Array;
/** Encode BranchDelete (5 bytes: branch u32 LE, confirm u8) */
export declare function encodeBranchDelete(branch: number, confirm?: boolean): Uint8Array;
/** Encode BranchConfirmFork (1 byte: confirm u8) */
export declare function encodeBranchConfirmFork(confirm?: boolean): Uint8Array;
/** Decode ForkStatus (14 bytes) */
export declare function decodeForkStatus(data: Uint8Array): ForkStatus;
/** Encode Seek argument (target []const u8) */
export declare function encodeSeek(target: string): Uint8Array;
/** Encode PlayArgs (9 bytes: dir u8, speed_milli u64 LE) */
export declare function encodePlayArgs(args: PlayArgs): Uint8Array;
/** Encode NavQueryArgs (kind u8, index u64 LE, name []const u8) */
export declare function encodeNavQueryArgs(args: NavQueryArgs): Uint8Array;
/** Decode NavQueryResult (43 bytes) */
export declare function decodeNavQueryResult(data: Uint8Array): NavQueryResult;
/** Encode MarkerSetArgs (name []const u8, place []const u8) */
export declare function encodeMarkerSetArgs(name: string, place: string): Uint8Array;
/** Decode FrameStatusResult (40 bytes) */
export declare function decodeFrameStatusResult(data: Uint8Array): FrameStatusResult;
/** Encode DiffArgs (a []const u8, b []const u8) */
export declare function encodeDiffArgs(a: string, b: string): Uint8Array;
/** Decode DiffWire reply from Method.Diff (0x013C) per diff_wire.zig */
export declare function decodeDiff(data: Uint8Array): DecodedDiff;
/** Encode single-frame Load argument (core u8, image []const u8) */
export declare function encodeLoad(core: Core, image: Uint8Array): Uint8Array;
/** Encode LoadBegin argument (13 bytes: core u8, total_len u64 LE, checksum u32 LE) */
export declare function encodeLoadBegin(core: Core, totalLen: bigint | number, checksum: number): Uint8Array;
/** Encode LoadChunk argument (13 + bytes.length: core u8, offset u64 LE, bytes []const u8) */
export declare function encodeLoadChunk(core: Core, offset: bigint | number, bytes: Uint8Array): Uint8Array;
/** Encode NamedBreak argument (core u8, name []const u8) */
export declare function encodeNamedBreak(core: Core, name: string): Uint8Array;
/** Decode NamedPoint reply (9 bytes: id u32 LE, address u32 LE, deferred u8) */
export declare function decodeNamedPoint(data: Uint8Array): NamedPointResult;
/** Encode Watchpoint argument (10 bytes: core u8, first u32 LE, last u32 LE, access u8) */
export declare function encodeWatchpoint(core: Core, first: number, last: number, access: Access): Uint8Array;
/** Encode MapAsk argument (2 bytes: core u8, json u8) */
export declare function encodeMapAsk(core: Core, json?: boolean): Uint8Array;
/** Decode SourceLine reply (found u8, pc u32 LE, line u32 LE, path []const u8) */
export declare function decodeSourceLine(data: Uint8Array): SourceLineResult;
/** Encode CoreFrame argument (5 bytes: core u8, frame u32 LE) */
export declare function encodeCoreFrame(core: Core, frame: number): Uint8Array;
/** Decode Locals reply (core u8, count u8, rows []const u8 of length-prefixed LocalRow) */
export declare function decodeLocals(data: Uint8Array): LocalsResult;
/** Decode Advanced reply (22 bytes: core u8, from_ns u64 LE, to_ns u64 LE, reason u8, address u32 LE) */
export declare function decodeAdvanced(data: Uint8Array): AdvancedResult;
//# sourceMappingURL=codec.d.ts.map