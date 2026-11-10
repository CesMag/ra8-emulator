/**
 * RA8 Binary Wire Protocol Codec
 *
 * Implements high-performance binary encoding and decoding using DataView
 * adhering to ra8_rpc_wire specifications and zero-padding struct layout.
 */
import { Kind, ErrorCode, Method, Topic, Core, Register, RunMode, RpcHeader, RpcRequestEnvelope, RpcResponseEnvelope, RpcEventEnvelope, Hello, Fault, MetricsReport, DirtyRect, Stopped, UartEvent, Ack } from "./types.js";
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
//# sourceMappingURL=codec.d.ts.map