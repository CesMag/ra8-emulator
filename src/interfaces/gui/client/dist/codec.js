/**
 * RA8 Binary Wire Protocol Codec
 *
 * Implements high-performance binary encoding and decoding using DataView
 * adhering to ra8_rpc_wire specifications and zero-padding struct layout.
 */
import { ErrorCode, HEADER_BYTES, METRICS_REPORT_BYTES, MAX_PAYLOAD, PROTOCOL_MAGIC, PROTOCOL_VERSION, } from "./types.js";
/** Encode the 6-byte frame header */
export function encodeHeader(length, kind) {
    const buf = new Uint8Array(HEADER_BYTES);
    const view = new DataView(buf.buffer);
    view.setUint32(0, length, true);
    view.setUint16(4, kind, true);
    return buf;
}
/** Decode the 6-byte frame header */
export function decodeHeader(data) {
    if (data.length < HEADER_BYTES) {
        throw new Error("Truncated frame header: requires 6 bytes");
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    return {
        length: view.getUint32(0, true),
        kind: view.getUint16(4, true),
    };
}
/** Wrap a payload into a framed binary packet with the 6-byte header */
export function encodeFrame(kind, payload) {
    const frame = new Uint8Array(HEADER_BYTES + payload.length);
    const view = new DataView(frame.buffer);
    view.setUint32(0, payload.length, true);
    view.setUint16(4, kind, true);
    frame.set(payload, HEADER_BYTES);
    return frame;
}
/** Parse and split contiguous frames from an incoming stream buffer */
export function splitFrames(buffer, maxPayload = MAX_PAYLOAD) {
    const frames = [];
    let offset = 0;
    while (buffer.length - offset >= HEADER_BYTES) {
        const view = new DataView(buffer.buffer, buffer.byteOffset + offset, HEADER_BYTES);
        const length = view.getUint32(0, true);
        const kind = view.getUint16(4, true);
        if (length > maxPayload) {
            throw new Error(`Frame payload oversize: ${length} > max ${maxPayload}`);
        }
        const totalFrameBytes = HEADER_BYTES + length;
        if (buffer.length - offset < totalFrameBytes) {
            // Partial frame; wait for more data
            break;
        }
        const payload = buffer.subarray(offset + HEADER_BYTES, offset + totalFrameBytes);
        frames.push({ kind, payload });
        offset += totalFrameBytes;
    }
    const remainder = offset < buffer.length ? buffer.subarray(offset) : new Uint8Array(0);
    return { frames, remainder };
}
/** Encode Hello payload (10 bytes: magic u32, version u16, caps u32) */
export function encodeHello(caps, magic = PROTOCOL_MAGIC, version = PROTOCOL_VERSION) {
    const buf = new Uint8Array(10);
    const view = new DataView(buf.buffer);
    view.setUint32(0, magic, true);
    view.setUint16(4, version, true);
    view.setUint32(6, caps, true);
    return buf;
}
/** Decode Hello payload */
export function decodeHello(payload) {
    if (payload.length < 10) {
        throw new Error("Truncated Hello frame: requires 10 bytes");
    }
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    return {
        magic: view.getUint32(0, true),
        version: view.getUint16(4, true),
        caps: view.getUint32(6, true),
    };
}
/** Encode Fault payload (4 bytes: code u16, version u16) */
export function encodeFault(code, version = PROTOCOL_VERSION) {
    const buf = new Uint8Array(4);
    const view = new DataView(buf.buffer);
    view.setUint16(0, code, true);
    view.setUint16(2, version, true);
    return buf;
}
/** Decode Fault payload */
export function decodeFault(payload) {
    if (payload.length < 4) {
        throw new Error("Truncated Fault frame: requires 4 bytes");
    }
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    return {
        code: view.getUint16(0, true),
        version: view.getUint16(2, true),
    };
}
/** Encode Request envelope */
export function encodeRequest(id, method, args) {
    const argsLen = args ? args.length : 0;
    const buf = new Uint8Array(4 + 2 + 4 + argsLen);
    const view = new DataView(buf.buffer);
    view.setUint32(0, id, true);
    view.setUint16(4, method, true);
    view.setUint32(6, argsLen, true);
    if (args && argsLen > 0) {
        buf.set(args, 10);
    }
    return buf;
}
/** Decode Request envelope */
export function decodeRequest(payload) {
    if (payload.length < 10) {
        throw new Error("Truncated Request envelope: requires at least 10 bytes");
    }
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    const id = view.getUint32(0, true);
    const method = view.getUint16(4, true);
    const argsLen = view.getUint32(6, true);
    if (payload.length < 10 + argsLen) {
        throw new Error("Truncated Request envelope args");
    }
    const args = payload.subarray(10, 10 + argsLen);
    return { id, method, args };
}
/** Encode Response envelope */
export function encodeResponse(id, ok, payloadOrCode) {
    if (ok) {
        const bytes = payloadOrCode instanceof Uint8Array ? payloadOrCode : new Uint8Array(0);
        const buf = new Uint8Array(4 + 1 + 4 + bytes.length);
        const view = new DataView(buf.buffer);
        view.setUint32(0, id, true);
        view.setUint8(4, 0); // ok tag = 0
        view.setUint32(5, bytes.length, true);
        buf.set(bytes, 9);
        return buf;
    }
    else {
        const code = typeof payloadOrCode === "number" ? payloadOrCode : ErrorCode.Failed;
        const buf = new Uint8Array(4 + 1 + 2);
        const view = new DataView(buf.buffer);
        view.setUint32(0, id, true);
        view.setUint8(4, 1); // err tag = 1
        view.setUint16(5, code, true);
        return buf;
    }
}
/** Decode Response envelope */
export function decodeResponse(payload) {
    if (payload.length < 5) {
        throw new Error("Truncated Response envelope: requires at least 5 bytes");
    }
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    const id = view.getUint32(0, true);
    const tag = view.getUint8(4);
    if (tag === 0) {
        // ok
        if (payload.length < 9) {
            throw new Error("Truncated Response payload length header");
        }
        const len = view.getUint32(5, true);
        if (payload.length < 9 + len) {
            throw new Error("Truncated Response payload body");
        }
        const body = payload.subarray(9, 9 + len);
        return { id, ok: true, payload: body };
    }
    else if (tag === 1) {
        // err
        if (payload.length < 7) {
            throw new Error("Truncated Response error code");
        }
        const code = view.getUint16(5, true);
        return { id, ok: false, code, payload: new Uint8Array(0) };
    }
    else {
        throw new Error(`Invalid Response result tag: ${tag}`);
    }
}
/** Encode Event envelope */
export function encodeEvent(topic, payload) {
    const buf = new Uint8Array(2 + 4 + payload.length);
    const view = new DataView(buf.buffer);
    view.setUint16(0, topic, true);
    view.setUint32(2, payload.length, true);
    buf.set(payload, 6);
    return buf;
}
/** Decode Event envelope */
export function decodeEvent(payload) {
    if (payload.length < 6) {
        throw new Error("Truncated Event envelope: requires at least 6 bytes");
    }
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    const topic = view.getUint16(0, true);
    const len = view.getUint32(2, true);
    if (payload.length < 6 + len) {
        throw new Error("Truncated Event payload body");
    }
    const body = payload.subarray(6, 6 + len);
    return { topic, payload: body };
}
/* -------------------------------------------------------------------------- */
/* Struct Codecs (matching rpc.zig & metrics_wire.zig canonical wire layout)  */
/* -------------------------------------------------------------------------- */
/** Encode CoreOnly argument (1 byte) */
export function encodeCoreOnly(core) {
    return new Uint8Array([core]);
}
/** Decode CoreOnly argument */
export function decodeCoreOnly(data) {
    if (data.length < 1)
        throw new Error("Truncated CoreOnly");
    return data[0];
}
/** Encode Run argument (10 bytes: core u8, mode u8, budget u64 LE) */
export function encodeRun(core, mode, budget = 0n) {
    const buf = new Uint8Array(10);
    const view = new DataView(buf.buffer);
    view.setUint8(0, core);
    view.setUint8(1, mode);
    view.setBigUint64(2, budget, true);
    return buf;
}
/** Encode ReadRegister argument (2 bytes: core u8, register u8) */
export function encodeReadRegister(core, register) {
    return new Uint8Array([core, register]);
}
/** Encode WriteRegister argument (6 bytes: core u8, register u8, value u32 LE) */
export function encodeWriteRegister(core, register, value) {
    const buf = new Uint8Array(6);
    const view = new DataView(buf.buffer);
    view.setUint8(0, core);
    view.setUint8(1, register);
    view.setUint32(2, value, true);
    return buf;
}
/** Encode ReadMemory argument (9 bytes: core u8, address u32 LE, length u32 LE) */
export function encodeReadMemory(core, address, length) {
    const buf = new Uint8Array(9);
    const view = new DataView(buf.buffer);
    view.setUint8(0, core);
    view.setUint32(1, address, true);
    view.setUint32(5, length, true);
    return buf;
}
/** Decode Memory result ([]const u8: u32 len LE + bytes) */
export function decodeMemory(data) {
    if (data.length < 4)
        throw new Error("Truncated Memory slice");
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const len = view.getUint32(0, true);
    if (data.length < 4 + len)
        throw new Error("Truncated Memory bytes");
    return data.subarray(4, 4 + len);
}
/** Encode WriteMemory argument (1 + 4 + 4 + bytes.length) */
export function encodeWriteMemory(core, address, bytes) {
    const buf = new Uint8Array(9 + bytes.length);
    const view = new DataView(buf.buffer);
    view.setUint8(0, core);
    view.setUint32(1, address, true);
    view.setUint32(5, bytes.length, true);
    buf.set(bytes, 9);
    return buf;
}
/** Encode Subscription argument (5 bytes: core u8, topic u16 LE, rate u16 LE) */
export function encodeSubscription(core, topic, rate = 0) {
    const buf = new Uint8Array(5);
    const view = new DataView(buf.buffer);
    view.setUint8(0, core);
    view.setUint16(1, topic, true);
    view.setUint16(3, rate, true);
    return buf;
}
/** Encode SetBreakpoint / ClearBreakpoint argument (5 bytes: core u8, address u32 LE) */
export function encodePoint(core, address) {
    const buf = new Uint8Array(5);
    const view = new DataView(buf.buffer);
    view.setUint8(0, core);
    view.setUint32(1, address, true);
    return buf;
}
/** Encode Advance argument (9 bytes: core u8, ns u64 LE) */
export function encodeAdvance(core, ns) {
    const buf = new Uint8Array(9);
    const view = new DataView(buf.buffer);
    view.setUint8(0, core);
    view.setBigUint64(1, ns, true);
    return buf;
}
/** Decode U32 result (4 bytes) */
export function decodeU32(data) {
    if (data.length < 4)
        throw new Error("Truncated U32");
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    return view.getUint32(0, true);
}
/** Encode U32 */
export function encodeU32(value) {
    const buf = new Uint8Array(4);
    const view = new DataView(buf.buffer);
    view.setUint32(0, value, true);
    return buf;
}
/** Decode Ack result (1 byte) */
export function decodeAck(data) {
    if (data.length < 1)
        throw new Error("Truncated Ack");
    return { accepted: data[0] ?? 0 };
}
/** Decode Stopped event (10 bytes: core u8, reason u8, address u32 LE, detail u32 LE) */
export function decodeStopped(data) {
    if (data.length < 10)
        throw new Error("Truncated Stopped event");
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    return {
        core: view.getUint8(0),
        reason: view.getUint8(1),
        address: view.getUint32(2, true),
        detail: view.getUint32(6, true),
    };
}
/** Decode Uart event (1 + 1 + 8 + 4 + bytes) */
export function decodeUart(data) {
    if (data.length < 14)
        throw new Error("Truncated Uart event header");
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const core = view.getUint8(0);
    const channel = view.getUint8(1);
    const virtualNs = view.getBigUint64(2, true);
    const len = view.getUint32(10, true);
    if (data.length < 14 + len)
        throw new Error("Truncated Uart bytes");
    const bytes = data.subarray(14, 14 + len);
    return { core, channel, virtualNs, bytes };
}
/** Decode MetricsReport (32-byte layout matching metrics_wire.zig) */
export function decodeMetricsReport(data) {
    if (data.length < METRICS_REPORT_BYTES) {
        throw new Error(`Truncated MetricsReport: requires ${METRICS_REPORT_BYTES} bytes`);
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    return {
        hostCpuPercent: view.getUint32(0, true),
        hostRssMb: view.getUint32(4, true),
        hostThreads: view.getUint32(8, true),
        cpu0LoadPercent: view.getUint8(12),
        cpu0Pinned: view.getUint8(13),
        cpu0RamUsedBytes: view.getUint32(14, true),
        cpu0RamTotalBytes: view.getUint32(18, true),
        cpu1LoadPercent: view.getUint8(22),
        cpu1Pinned: view.getUint8(23),
        cpu1RamUsedBytes: view.getUint32(24, true),
        cpu1RamTotalBytes: view.getUint32(28, true),
    };
}
/** Encode MetricsReport (32 bytes) */
export function encodeMetricsReport(report) {
    const buf = new Uint8Array(METRICS_REPORT_BYTES);
    const view = new DataView(buf.buffer);
    view.setUint32(0, report.hostCpuPercent, true);
    view.setUint32(4, report.hostRssMb, true);
    view.setUint32(8, report.hostThreads, true);
    view.setUint8(12, report.cpu0LoadPercent);
    view.setUint8(13, report.cpu0Pinned);
    view.setUint32(14, report.cpu0RamUsedBytes, true);
    view.setUint32(18, report.cpu0RamTotalBytes, true);
    view.setUint8(22, report.cpu1LoadPercent);
    view.setUint8(23, report.cpu1Pinned);
    view.setUint32(24, report.cpu1RamUsedBytes, true);
    view.setUint32(28, report.cpu1RamTotalBytes, true);
    return buf;
}
/** Decode DirtyRect (21 bytes header + pixel data matching rpc.zig) */
export function decodeDirtyRect(data) {
    if (data.length < 21) {
        throw new Error("Truncated DirtyRect: requires at least 21 bytes header");
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const core = view.getUint8(0);
    const x = view.getUint16(1, true);
    const y = view.getUint16(3, true);
    const width = view.getUint16(5, true);
    const height = view.getUint16(7, true);
    const virtualNs = view.getBigUint64(9, true);
    const pixelLen = view.getUint32(17, true);
    if (data.length < 21 + pixelLen) {
        throw new Error("Truncated DirtyRect pixel buffer");
    }
    const pixels = data.subarray(21, 21 + pixelLen);
    return { core, x, y, width, height, virtualNs, pixels };
}
/** Encode DirtyRect */
export function encodeDirtyRect(rect) {
    const pixelLen = rect.pixels.length;
    const buf = new Uint8Array(21 + pixelLen);
    const view = new DataView(buf.buffer);
    view.setUint8(0, rect.core);
    view.setUint16(1, rect.x, true);
    view.setUint16(3, rect.y, true);
    view.setUint16(5, rect.width, true);
    view.setUint16(7, rect.height, true);
    view.setBigUint64(9, rect.virtualNs, true);
    view.setUint32(17, pixelLen, true);
    buf.set(rect.pixels, 21);
    return buf;
}
/** Encode SetSpeed argument (9 bytes: core u8, milli u64 LE) */
export function encodeSetSpeed(core, milli) {
    const buf = new Uint8Array(9);
    const view = new DataView(buf.buffer);
    view.setUint8(0, core);
    view.setBigUint64(1, BigInt(milli), true);
    return buf;
}
/** Encode ScheduleInput argument (27 bytes) */
export function encodeScheduleInput(args) {
    const buf = new Uint8Array(27);
    const view = new DataView(buf.buffer);
    view.setUint8(0, args.core);
    view.setBigUint64(1, BigInt(args.atNs ?? 0n), true);
    view.setUint8(9, args.kind);
    view.setUint16(10, args.x ?? 0, true);
    view.setUint16(12, args.y ?? 0, true);
    view.setUint16(14, args.toX ?? 0, true);
    view.setUint16(16, args.toY ?? 0, true);
    view.setBigUint64(18, BigInt(args.durationNs ?? 0n), true);
    view.setUint8(26, args.button ?? 0);
    return buf;
}
/** Encode ConsoleInput argument (1 + 4 + bytes.length) */
export function encodeConsoleInput(core, bytes) {
    const buf = new Uint8Array(1 + 4 + bytes.length);
    const view = new DataView(buf.buffer);
    view.setUint8(0, core);
    view.setUint32(1, bytes.length, true);
    buf.set(bytes, 5);
    return buf;
}
/** Decode SessionEvent (6 bytes: core u8, kind u8, address u32 LE) */
export function decodeSessionEvent(data) {
    if (data.length < 6) {
        throw new Error("Truncated SessionEvent");
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    return {
        core: view.getUint8(0),
        kind: view.getUint8(1),
        address: view.getUint32(2, true),
    };
}
function readSlice(data, offset) {
    if (offset.val + 4 > data.length)
        throw new Error("Truncated slice length");
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const len = view.getUint32(offset.val, true);
    offset.val += 4;
    if (offset.val + len > data.length)
        throw new Error("Truncated slice data");
    const slice = data.subarray(offset.val, offset.val + len);
    offset.val += len;
    return slice;
}
/** Decode BoardParts reply */
export function decodeBoardParts(data) {
    const offset = { val: 0 };
    const decoder = new TextDecoder();
    const panel = decoder.decode(readSlice(data, offset));
    if (offset.val + 8 > data.length)
        throw new Error("Truncated BoardParts dims");
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const panelWidth = view.getUint32(offset.val, true);
    offset.val += 4;
    const panelHeight = view.getUint32(offset.val, true);
    offset.val += 4;
    const ledNamesRaw = decoder.decode(readSlice(data, offset));
    const ledNames = ledNamesRaw.length > 0 ? ledNamesRaw.split("\n") : [];
    const ledColorsRaw = readSlice(data, offset);
    const ledColors = [];
    const colorView = new DataView(ledColorsRaw.buffer, ledColorsRaw.byteOffset, ledColorsRaw.byteLength);
    for (let i = 0; i + 1 < ledColorsRaw.length; i += 2) {
        ledColors.push(colorView.getUint16(i, true));
    }
    const switchNamesRaw = decoder.decode(readSlice(data, offset));
    const switchNames = switchNamesRaw.length > 0 ? switchNamesRaw.split("\n") : [];
    return { panel, panelWidth, panelHeight, ledNames, ledColors, switchNames };
}
/** Decode Backtrace reply */
export function decodeBacktrace(data) {
    if (data.length < 6)
        throw new Error("Truncated Backtrace header");
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const core = view.getUint8(0);
    const count = view.getUint8(1);
    const framesLen = view.getUint32(2, true);
    const framesBytes = data.subarray(6, 6 + framesLen);
    const frames = [];
    let at = 0;
    const decoder = new TextDecoder();
    for (let i = 0; i < count && at < framesBytes.length; i++) {
        const frameLen = framesBytes[at];
        if (frameLen === undefined)
            break;
        at += 1;
        if (at + frameLen > framesBytes.length)
            break;
        const fData = framesBytes.subarray(at, at + frameLen);
        at += frameLen;
        if (fData.length < 13)
            continue;
        const fView = new DataView(fData.buffer, fData.byteOffset, fData.byteLength);
        const pc = fView.getUint32(0, true);
        const interrupted = fView.getUint8(4);
        const fOffset = fView.getUint32(5, true);
        const line = fView.getUint32(9, true);
        const fSliceOffset = { val: 13 };
        const name = decoder.decode(readSlice(fData, fSliceOffset));
        const file = decoder.decode(readSlice(fData, fSliceOffset));
        frames.push({ pc, interrupted, offset: fOffset, line, name, file });
    }
    return { core, count, frames };
}
//# sourceMappingURL=codec.js.map