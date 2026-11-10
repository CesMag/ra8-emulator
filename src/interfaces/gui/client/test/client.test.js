/**
 * Automated Node.js Integration & Unit Test Suite for ra8-rpc-client
 *
 * Verifies:
 * 1. Wire codec roundtrips (headers, envelopes, hello, fault, request, response, event).
 * 2. 32-byte MetricsReport exact binary layout & field integrity.
 * 3. DirtyRect binary encoding, decoding, and pixel format conversions.
 * 4. Stream framing & frame splitting over fragmented buffers.
 * 5. Full Method (0x0100..0x013C) and Topic (0x0100..0x0106) enum completeness.
 * 6. End-to-end WebSocket client operations (handshake, step, run, pause, registers, memory, metrics, subscriptions, events, disconnect).
 */

import assert from 'node:assert/strict';

import {
  Kind,
  ErrorCode,
  Method,
  Topic,
  Core,
  Register,
  RunMode,
  StopReason,
  PROTOCOL_MAGIC,
  PROTOCOL_VERSION,
  HEADER_BYTES,
  METRICS_REPORT_BYTES,
  encodeHeader,
  decodeHeader,
  encodeFrame,
  splitFrames,
  encodeHello,
  decodeHello,
  encodeFault,
  decodeFault,
  encodeRequest,
  decodeRequest,
  encodeResponse,
  decodeResponse,
  encodeEvent,
  decodeEvent,
  encodeMetricsReport,
  decodeMetricsReport,
  encodeDirtyRect,
  decodeDirtyRect,
  encodeCoreOnly,
  decodeCoreOnly,
  encodeRun,
  encodeReadRegister,
  encodeWriteRegister,
  encodeReadMemory,
  decodeMemory,
  encodeWriteMemory,
  encodeSubscription,
  encodePoint,
  encodeAdvance,
  encodeSetSpeed,
  encodeScheduleInput,
  encodeConsoleInput,
  decodeSessionEvent,
  decodeBoardParts,
  decodeBacktrace,
  encodeDisasmAsk,
  decodeDisasmReply,
  decodeStackReport,
  decodeBranchList,
  decodeForkStatus,
  decodeDiff,
  ForkReason,
  decodeU32,
  encodeU32,
  decodeAck,
  decodeStopped,
  decodeUart,
  dirtyRectToRgba,
  detectPixelFormat,
  RA8RpcClient,
} from '../dist/index.js';

let testsPassed = 0;
let testsFailed = 0;

function runTest(name, fn) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
    testsPassed++;
  } catch (err) {
    console.error(`  ✗ ${name}`);
    console.error(err);
    testsFailed++;
  }
}

async function runAsyncTest(name, fn) {
  try {
    await fn();
    console.log(`  ✓ ${name}`);
    testsPassed++;
  } catch (err) {
    console.error(`  ✗ ${name}`);
    console.error(err);
    testsFailed++;
  }
}

console.log('=== RA8 TypeScript RPC Client Test Suite ===\n');

/* -------------------------------------------------------------------------- */
/* Test Group 1: Enum Verification                                            */
/* -------------------------------------------------------------------------- */
console.log('--- Test Group 1: Enum & Schema Completeness ---');

runTest('all Method opcodes are defined from 0x0100 through 0x013D', () => {
  const methodValues = Object.values(Method).filter(v => typeof v === 'number');
  assert.equal(methodValues.length, 61, 'Expected all 61 Method opcodes across 0x0100..0x013D');
  assert.equal(Method.Load, 0x0100);
  assert.equal(Method.Run, 0x0101);
  assert.equal(Method.Pause, 0x0102);
  assert.equal(Method.Step, 0x0103);
  assert.equal(Method.SetSpeed, 0x0104);
  assert.equal(Method.ReadRegister, 0x0105);
  assert.equal(Method.WriteRegister, 0x0106);
  assert.equal(Method.ReadMemory, 0x0107);
  assert.equal(Method.WriteMemory, 0x0108);
  assert.equal(Method.SetBreakpoint, 0x0109);
  assert.equal(Method.ClearBreakpoint, 0x010A);
  assert.equal(Method.SetWatchpoint, 0x010B);
  assert.equal(Method.ClearWatchpoint, 0x010C);
  assert.equal(Method.Subscribe, 0x010D);
  assert.equal(Method.Unsubscribe, 0x010E);
  assert.equal(Method.Now, 0x010F);
  assert.equal(Method.Interrupt, 0x0110);
  assert.equal(Method.SetRunBudget, 0x0111);
  assert.equal(Method.RemovePoint, 0x0112);
  assert.equal(Method.Plug, 0x0113);
  assert.equal(Method.Unplug, 0x0114);
  assert.equal(Method.SetFault, 0x0115);
  assert.equal(Method.ClearFault, 0x0116);
  assert.equal(Method.Advance, 0x0117);
  assert.equal(Method.Snapshot, 0x0118);
  assert.equal(Method.Restore, 0x0119);
  assert.equal(Method.ListParts, 0x011A);
  assert.equal(Method.SetCameraSource, 0x011B);
  assert.equal(Method.Map, 0x011C);
  assert.equal(Method.Stack, 0x011D);
  assert.equal(Method.Rtc, 0x011E);
  assert.equal(Method.Input, 0x011F);
  assert.equal(Method.Backtrace, 0x0120);
  assert.equal(Method.Periph, 0x0121);
  assert.equal(Method.Folded, 0x0122);
  assert.equal(Method.SetBreakpointName, 0x0123);
  assert.equal(Method.LoadBegin, 0x0124);
  assert.equal(Method.LoadChunk, 0x0125);
  assert.equal(Method.LoadEnd, 0x0126);
  assert.equal(Method.BoardParts, 0x0127);
  assert.equal(Method.SourceLine, 0x0128);
  assert.equal(Method.Locals, 0x0129);
  assert.equal(Method.LocalsAt, 0x012A);
  assert.equal(Method.AdvanceAsync, 0x012B);
  assert.equal(Method.Seek, 0x012C);
  assert.equal(Method.Rcont, 0x012D);
  assert.equal(Method.Metrics, 0x012E);
  assert.equal(Method.BranchList, 0x0130);
  assert.equal(Method.BranchSwitch, 0x0131);
  assert.equal(Method.BranchDelete, 0x0132);
  assert.equal(Method.BranchConfirmFork, 0x0133);
  assert.equal(Method.BranchCancelFork, 0x0134);
  assert.equal(Method.BranchStatus, 0x0135);
  assert.equal(Method.ConsoleInput, 0x0136);
  assert.equal(Method.SkipBkpt, 0x0137);
  assert.equal(Method.Play, 0x0138);
  assert.equal(Method.NavQuery, 0x0139);
  assert.equal(Method.MarkerSet, 0x013A);
  assert.equal(Method.FrameStatus, 0x013B);
  assert.equal(Method.Diff, 0x013C);
  assert.equal(Method.Disasm, 0x013D);
});

runTest('all 7 Topic event codes are defined from 0x0100 through 0x0106', () => {
  const topicValues = Object.values(Topic).filter(v => typeof v === 'number');
  assert.equal(topicValues.length, 7);
  assert.equal(Topic.Stop, 0x0100);
  assert.equal(Topic.Uart, 0x0101);
  assert.equal(Topic.Speed, 0x0102);
  assert.equal(Topic.LcdDirty, 0x0103);
  assert.equal(Topic.Trace, 0x0104);
  assert.equal(Topic.Session, 0x0105);
  assert.equal(Topic.Transport, 0x0106);
});

/* -------------------------------------------------------------------------- */
/* Test Group 2: Binary Codec Roundtrips                                      */
/* -------------------------------------------------------------------------- */
console.log('\n--- Test Group 2: Binary Codec Roundtrips ---');

runTest('Header encode and decode roundtrip', () => {
  const encoded = encodeHeader(1024, Kind.Request);
  assert.equal(encoded.length, HEADER_BYTES);
  const decoded = decodeHeader(encoded);
  assert.equal(decoded.length, 1024);
  assert.equal(decoded.kind, Kind.Request);
});

runTest('Hello handshake frame roundtrip', () => {
  const caps = 0x00007FFF;
  const payload = encodeHello(caps);
  assert.equal(payload.length, 10);
  const hello = decodeHello(payload);
  assert.equal(hello.magic, PROTOCOL_MAGIC);
  assert.equal(hello.version, PROTOCOL_VERSION);
  assert.equal(hello.caps, caps);
});

runTest('Fault frame roundtrip', () => {
  const payload = encodeFault(ErrorCode.BadArgs);
  assert.equal(payload.length, 4);
  const fault = decodeFault(payload);
  assert.equal(fault.code, ErrorCode.BadArgs);
  assert.equal(fault.version, PROTOCOL_VERSION);
});

runTest('Request envelope roundtrip with args', () => {
  const args = new Uint8Array([0x01, 0x02, 0x03, 0x04]);
  const payload = encodeRequest(42, Method.Step, args);
  assert.equal(payload.length, 4 + 2 + 4 + 4);
  const req = decodeRequest(payload);
  assert.equal(req.id, 42);
  assert.equal(req.method, Method.Step);
  assert.deepEqual(Array.from(req.args), [1, 2, 3, 4]);
});

runTest('Request envelope roundtrip with empty args', () => {
  const payload = encodeRequest(99, Method.Pause);
  assert.equal(payload.length, 10);
  const req = decodeRequest(payload);
  assert.equal(req.id, 99);
  assert.equal(req.method, Method.Pause);
  assert.equal(req.args.length, 0);
});

runTest('Response envelope roundtrip with Ok outcome', () => {
  const okData = new Uint8Array([0xAA, 0xBB, 0xCC]);
  const payload = encodeResponse(77, true, okData);
  assert.equal(payload.length, 4 + 1 + 4 + 3);
  const resp = decodeResponse(payload);
  assert.equal(resp.id, 77);
  assert.equal(resp.ok, true);
  assert.deepEqual(Array.from(resp.payload), [0xAA, 0xBB, 0xCC]);
});

runTest('Response envelope roundtrip with Err outcome', () => {
  const payload = encodeResponse(88, false, ErrorCode.UnknownMethod);
  assert.equal(payload.length, 4 + 1 + 2);
  const resp = decodeResponse(payload);
  assert.equal(resp.id, 88);
  assert.equal(resp.ok, false);
  assert.equal(resp.code, ErrorCode.UnknownMethod);
});

runTest('Event envelope roundtrip', () => {
  const eventData = new Uint8Array([0x10, 0x20, 0x30]);
  const payload = encodeEvent(Topic.Uart, eventData);
  assert.equal(payload.length, 2 + 4 + 3);
  const event = decodeEvent(payload);
  assert.equal(event.topic, Topic.Uart);
  assert.deepEqual(Array.from(event.payload), [0x10, 0x20, 0x30]);
});

runTest('encodeSetSpeed encodes core and milli u64 LE', () => {
  const buf = encodeSetSpeed(Core.Cpu0, 100n);
  assert.equal(buf.length, 1 + 8);
  assert.equal(buf[0], Core.Cpu0);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  assert.equal(view.getBigUint64(1, true), 100n);
});

runTest('encodeScheduleInput encodes input args to 27 bytes', () => {
  const btn = encodeScheduleInput({ core: Core.Cpu0, kind: 0, button: 1 });
  assert.equal(btn.length, 27);
  assert.equal(btn[0], Core.Cpu0);
  assert.equal(btn[9], 0); // kind = 0
  assert.equal(btn[26], 1); // button = 1

  const touch = encodeScheduleInput({ core: Core.Cpu0, kind: 1, x: 250, y: 150 });
  assert.equal(touch.length, 27);
  assert.equal(touch[0], Core.Cpu0);
  assert.equal(touch[9], 1); // kind = 1
  const v = new DataView(touch.buffer, touch.byteOffset, touch.byteLength);
  assert.equal(v.getUint16(10, true), 250);
  assert.equal(v.getUint16(12, true), 150);
});

runTest('encodeConsoleInput encodes core and payload bytes', () => {
  const data = new TextEncoder().encode('test');
  const buf = encodeConsoleInput(Core.Cpu0, data);
  assert.equal(buf.length, 1 + 4 + 4);
  assert.equal(buf[0], Core.Cpu0);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  assert.equal(view.getUint32(1, true), 4);
  assert.deepEqual(Array.from(buf.slice(5)), Array.from(data));
});

runTest('decodeSessionEvent parses session event kinds', () => {
  const buf = new Uint8Array([0, 15, 0x00, 0x10, 0x00, 0x00]); // Core 0, LedChanged = 15, address 0x1000
  const ev = decodeSessionEvent(buf);
  assert.equal(ev.core, Core.Cpu0);
  assert.equal(ev.kind, 15);
  assert.equal(ev.address, 0x1000);
});

runTest('encodeDisasmAsk and decodeDisasmReply roundtrip Zig disasm_wire binary layout', () => {
  const ask = encodeDisasmAsk({ core: Core.Cpu0, address: 0x02000100, count: 16, usePc: true });
  assert.equal(ask.length, 7);
  assert.equal(ask[0], Core.Cpu0);
  assert.equal(new DataView(ask.buffer).getUint32(1, true), 0x02000100);
  assert.equal(ask[5], 16);
  assert.equal(ask[6], 1);

  const textBytes = new TextEncoder().encode('movs r0, #42');
  const symBytes = new TextEncoder().encode('Reset_Handler');
  const rowLen = 4 + 1 + 1 + 4 + 1 + textBytes.length + 1 + symBytes.length;
  const replyBuf = new Uint8Array(10 + rowLen);
  const rv = new DataView(replyBuf.buffer);
  rv.setUint8(0, Core.Cpu0);
  rv.setUint32(1, 0x02000100, true);
  rv.setUint8(5, 1);
  rv.setUint32(6, rowLen, true);
  let at = 10;
  rv.setUint32(at, 0x02000100, true); at += 4;
  rv.setUint8(at++, 2);
  rv.setUint8(at++, 1);
  replyBuf.set([0x2a, 0x20, 0x00, 0x00], at); at += 4;
  rv.setUint8(at++, textBytes.length);
  replyBuf.set(textBytes, at); at += textBytes.length;
  rv.setUint8(at++, symBytes.length);
  replyBuf.set(symBytes, at);

  const reply = decodeDisasmReply(replyBuf);
  assert.equal(reply.core, Core.Cpu0);
  assert.equal(reply.pc, 0x02000100);
  assert.equal(reply.rows.length, 1);
  assert.equal(reply.rows[0].address, 0x02000100);
  assert.equal(reply.rows[0].size, 2);
  assert.equal(reply.rows[0].decoded, true);
  assert.equal(reply.rows[0].text, 'movs r0, #42');
  assert.equal(reply.rows[0].symbol, 'Reset_Handler');
});

runTest('decodeStackReport, decodeBranchList, decodeForkStatus, and decodeDiff parse Zig layouts', () => {
  const stackBuf = new Uint8Array(30);
  const sv = new DataView(stackBuf.buffer);
  sv.setUint8(0, Core.Cpu0);
  sv.setUint32(1, 0x22010000, true);
  sv.setUint32(5, 0x22008000, true);
  sv.setUint32(9, 0x2200fe00, true);
  sv.setUint32(13, 0x22007f00, true);
  sv.setUint8(17, 1);
  sv.setUint32(18, 0x2200f000, true);
  sv.setUint32(22, 0x1000, true);
  sv.setUint32(26, 0, true);
  const sr = decodeStackReport(stackBuf);
  assert.equal(sr.msp, 0x22010000);
  assert.equal(sr.lowMsp, 0x2200fe00);
  assert.equal(sr.hasStack, true);
  assert.equal(sr.size, 0x1000);

  const branchBuf = new Uint8Array(8 + 30);
  const bv = new DataView(branchBuf.buffer);
  bv.setUint32(0, 1, true);
  bv.setUint32(4, 30, true);
  bv.setUint32(8, 2, true); // id
  bv.setUint32(12, 1, true); // parent
  bv.setBigUint64(16, 1200n, true); // forkR
  bv.setBigUint64(24, 2400n, true); // recordedEndR
  bv.setUint32(32, 0, true); // childCount
  bv.setUint8(36, ForkReason.Writes);
  bv.setUint8(37, 0b11); // live + kept
  const branches = decodeBranchList(branchBuf);
  assert.equal(branches.length, 1);
  assert.equal(branches[0].id, 2);
  assert.equal(branches[0].parent, 1);
  assert.equal(branches[0].forkR, 1200n);
  assert.equal(branches[0].reason, ForkReason.Writes);
  assert.equal(branches[0].isLive, true);
  assert.equal(branches[0].isKept, true);

  const forkBuf = new Uint8Array(14);
  const fv = new DataView(forkBuf.buffer);
  fv.setUint8(0, 1);
  fv.setUint8(1, ForkReason.Buttons);
  fv.setUint32(2, 1, true);
  fv.setBigUint64(6, 512n, true);
  const fs = decodeForkStatus(forkBuf);
  assert.equal(fs.pending, true);
  assert.equal(fs.reason, ForkReason.Buttons);
  assert.equal(fs.r, 512n);

  const diffBody = new Uint8Array(32 + 12);
  const dv = new DataView(diffBody.buffer);
  dv.setUint16(0, 1, true); // 1 reg
  dv.setUint16(2, 0, true);
  dv.setUint16(4, 0, true);
  dv.setUint16(6, 8, true); // 8 frames
  dv.setUint32(8, 0, true);
  dv.setBigUint64(12, 100n, true);
  dv.setUint32(20, 1, true);
  dv.setBigUint64(24, 200n, true);
  dv.setUint8(32, Core.Cpu0);
  dv.setUint8(33, 2);
  diffBody.set([0x72, 0x30], 34); // 'r0'
  dv.setUint32(36, 0x10, true);
  dv.setUint32(40, 0x42, true);
  const diffOuter = new Uint8Array(4 + diffBody.length);
  new DataView(diffOuter.buffer).setUint32(0, diffBody.length, true);
  diffOuter.set(diffBody, 4);
  const diff = decodeDiff(diffOuter);
  assert.equal(diff.frames, 8);
  assert.equal(diff.b.branch, 1);
  assert.equal(diff.regs.length, 1);
  assert.equal(diff.regs[0].name, 'r0');
  assert.equal(diff.regs[0].valB, 0x42);
});

runTest('decodeBoardParts parses panel, dimensions, LEDs and switches', () => {
  // Construct board parts payload using 4-byte LE length prefixes
  const panelBytes = new TextEncoder().encode('TestPanel');
  const ledNames = new TextEncoder().encode('LED1\nLED2');
  const swNames = new TextEncoder().encode('SW1');

  const buf = new Uint8Array(256);
  let off = 0;
  // panel slice
  new DataView(buf.buffer).setUint32(off, panelBytes.length, true); off += 4;
  buf.set(panelBytes, off); off += panelBytes.length;
  // width & height
  new DataView(buf.buffer).setUint32(off, 800, true); off += 4;
  new DataView(buf.buffer).setUint32(off, 480, true); off += 4;
  // ledNames slice
  new DataView(buf.buffer).setUint32(off, ledNames.length, true); off += 4;
  buf.set(ledNames, off); off += ledNames.length;
  // ledColors slice
  new DataView(buf.buffer).setUint32(off, 4, true); off += 4;
  new DataView(buf.buffer).setUint16(off, 0xF800, true); off += 2;
  new DataView(buf.buffer).setUint16(off, 0x001F, true); off += 2;
  // switchNames slice
  new DataView(buf.buffer).setUint32(off, swNames.length, true); off += 4;
  buf.set(swNames, off); off += swNames.length;

  const parts = decodeBoardParts(buf.subarray(0, off));
  assert.equal(parts.panel, 'TestPanel');
  assert.equal(parts.panelWidth, 800);
  assert.equal(parts.panelHeight, 480);
  assert.deepEqual(parts.ledNames, ['LED1', 'LED2']);
  assert.deepEqual(parts.ledColors, [0xF800, 0x001F]);
  assert.deepEqual(parts.switchNames, ['SW1']);
});

runTest('decodeBacktrace parses stack frames', () => {
  const buf = new Uint8Array(6);
  buf[0] = Core.Cpu0;
  buf[1] = 0; // count = 0
  new DataView(buf.buffer).setUint32(2, 0, true); // framesLen = 0

  const bt = decodeBacktrace(buf);
  assert.equal(bt.core, Core.Cpu0);
  assert.equal(bt.count, 0);
  assert.equal(bt.frames.length, 0);
});

/* -------------------------------------------------------------------------- */
/* Test Group 3: MetricsReport 32-Byte Wire Layout                            */
/* -------------------------------------------------------------------------- */
console.log('\n--- Test Group 3: MetricsReport Wire Layout (32 Bytes) ---');

runTest('MetricsReport encode and decode matches exact 32-byte layout', () => {
  const report = {
    hostCpuPercent: 45,
    hostRssMb: 128,
    hostThreads: 8,
    cpu0LoadPercent: 72,
    cpu0Pinned: 1,
    cpu0RamUsedBytes: 0x00040000,
    cpu0RamTotalBytes: 0x00200000,
    cpu1LoadPercent: 15,
    cpu1Pinned: 0,
    cpu1RamUsedBytes: 0x00010000,
    cpu1RamTotalBytes: 0x00100000,
  };

  const bytes = encodeMetricsReport(report);
  assert.equal(bytes.length, METRICS_REPORT_BYTES, 'Must be exactly 32 bytes');

  // Verify byte offsets manually
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.equal(view.getUint32(0, true), 45);
  assert.equal(view.getUint32(4, true), 128);
  assert.equal(view.getUint32(8, true), 8);
  assert.equal(view.getUint8(12), 72);
  assert.equal(view.getUint8(13), 1);
  assert.equal(view.getUint32(14, true), 0x00040000);
  assert.equal(view.getUint32(18, true), 0x00200000);
  assert.equal(view.getUint8(22), 15);
  assert.equal(view.getUint8(23), 0);
  assert.equal(view.getUint32(24, true), 0x00010000);
  assert.equal(view.getUint32(28, true), 0x00100000);

  const decoded = decodeMetricsReport(bytes);
  assert.deepEqual(decoded, report);
});

/* -------------------------------------------------------------------------- */
/* Test Group 4: DirtyRect & Framebuffer Helpers                              */
/* -------------------------------------------------------------------------- */
console.log('\n--- Test Group 4: DirtyRect & Framebuffer Helpers ---');

runTest('DirtyRect encode and decode roundtrip', () => {
  const pixels = new Uint8Array([10, 20, 30, 40, 50, 60]);
  const rect = {
    core: Core.Cpu0,
    x: 100,
    y: 200,
    width: 3,
    height: 2,
    virtualNs: 1234567890123n,
    pixels,
  };

  const bytes = encodeDirtyRect(rect);
  assert.equal(bytes.length, 21 + 6);

  const decoded = decodeDirtyRect(bytes);
  assert.equal(decoded.core, Core.Cpu0);
  assert.equal(decoded.x, 100);
  assert.equal(decoded.y, 200);
  assert.equal(decoded.width, 3);
  assert.equal(decoded.height, 2);
  assert.equal(decoded.virtualNs, 1234567890123n);
  assert.deepEqual(Array.from(decoded.pixels), [10, 20, 30, 40, 50, 60]);
});

runTest('dirtyRectToRgba converts grayscale to RGBA', () => {
  const rect = {
    core: Core.Cpu0,
    x: 0,
    y: 0,
    width: 2,
    height: 1,
    virtualNs: 0n,
    pixels: new Uint8Array([128, 255]),
  };

  assert.equal(detectPixelFormat(rect), 'grayscale');
  const rgba = dirtyRectToRgba(rect);
  assert.equal(rgba.length, 8);
  // Pixel 0: 128, 128, 128, 255
  assert.equal(rgba[0], 128);
  assert.equal(rgba[1], 128);
  assert.equal(rgba[2], 128);
  assert.equal(rgba[3], 255);
  // Pixel 1: 255, 255, 255, 255
  assert.equal(rgba[4], 255);
  assert.equal(rgba[5], 255);
  assert.equal(rgba[6], 255);
  assert.equal(rgba[7], 255);
});

runTest('dirtyRectToRgba converts RGB565 to RGBA', () => {
  // Red in RGB565 is 0xF800 (bits: 11111 000000 00000) -> bytes: [0x00, 0xF8]
  const rect = {
    core: Core.Cpu0,
    x: 0,
    y: 0,
    width: 1,
    height: 1,
    virtualNs: 0n,
    pixels: new Uint8Array([0x00, 0xF8]),
  };

  assert.equal(detectPixelFormat(rect), 'rgb565');
  const rgba = dirtyRectToRgba(rect);
  assert.equal(rgba.length, 4);
  assert.equal(rgba[0], 255); // Red
  assert.equal(rgba[1], 0);   // Green
  assert.equal(rgba[2], 0);   // Blue
  assert.equal(rgba[3], 255); // Alpha
});

/* -------------------------------------------------------------------------- */
/* Test Group 5: Frame Splitting & Streaming Reassembly                       */
/* -------------------------------------------------------------------------- */
console.log('\n--- Test Group 5: Frame Splitting & Stream Reassembly ---');

runTest('splitFrames parses multiple complete frames', () => {
  const frame1 = encodeFrame(Kind.Hello, encodeHello(0x1234));
  const frame2 = encodeFrame(Kind.Event, encodeEvent(Topic.Speed, new Uint8Array([1, 2])));

  const combined = new Uint8Array(frame1.length + frame2.length);
  combined.set(frame1, 0);
  combined.set(frame2, frame1.length);

  const { frames, remainder } = splitFrames(combined);
  assert.equal(frames.length, 2);
  assert.equal(frames[0].kind, Kind.Hello);
  assert.equal(frames[1].kind, Kind.Event);
  assert.equal(remainder.length, 0);
});

runTest('splitFrames handles partial trailing bytes as remainder', () => {
  const frame = encodeFrame(Kind.Hello, encodeHello(0x1234));
  const partial = new Uint8Array(frame.length + 3);
  partial.set(frame, 0);
  partial.set([0x99, 0x88, 0x77], frame.length);

  const { frames, remainder } = splitFrames(partial);
  assert.equal(frames.length, 1);
  assert.equal(frames[0].kind, Kind.Hello);
  assert.equal(remainder.length, 3);
  assert.deepEqual(Array.from(remainder), [0x99, 0x88, 0x77]);
});

/* -------------------------------------------------------------------------- */
/* Test Group 6: Live WebSocket Client Operations & Mock Server               */
/* -------------------------------------------------------------------------- */
console.log('\n--- Test Group 6: Live / Mock WebSocket Client Operations ---');

/**
 * In-memory MockWebSocket implementation adhering to W3C WebSocket interface.
 * Implements full server-side RPC logic and framing without OS network sockets.
 */
class MockWebSocketServer {
  constructor() {
    this.client = null;
  }

  attach(clientWs) {
    this.client = clientWs;
  }

  handleClientFrame(rawBuffer) {
    const data = new Uint8Array(rawBuffer);
    const { frames } = splitFrames(data);

    for (const frame of frames) {
      if (frame.kind === Kind.Hello) {
        // Step 1: Handshake response
        const serverHelloPayload = encodeHello(0x0000ffff);
        const serverHelloPacket = encodeFrame(Kind.Hello, serverHelloPayload);
        this.sendToClient(serverHelloPacket);
      } else if (frame.kind === Kind.Request) {
        const req = decodeRequest(frame.payload);
        switch (req.method) {
          case Method.Step:
          case Method.Run:
          case Method.Pause:
          case Method.WriteMemory:
          case Method.WriteRegister:
          case Method.Subscribe:
          case Method.Unsubscribe:
          case Method.SetBreakpoint:
          case Method.ClearBreakpoint:
          case Method.Advance:
          case Method.SetSpeed:
          case Method.Input:
          case Method.ConsoleInput: {
            const ackPayload = new Uint8Array([1]); // accepted = 1
            const resp = encodeResponse(req.id, true, ackPayload);
            this.sendToClient(encodeFrame(Kind.Response, resp));
            break;
          }

          case Method.BoardParts: {
            const panel = new TextEncoder().encode('MockPanel');
            const buf = new Uint8Array(128);
            let off = 0;
            new DataView(buf.buffer).setUint32(off, panel.length, true); off += 4;
            buf.set(panel, off); off += panel.length;
            new DataView(buf.buffer).setUint32(off, 1024, true); off += 4;
            new DataView(buf.buffer).setUint32(off, 600, true); off += 4;
            new DataView(buf.buffer).setUint32(off, 0, true); off += 4; // 0 ledNames
            new DataView(buf.buffer).setUint32(off, 0, true); off += 4; // 0 ledColors
            new DataView(buf.buffer).setUint32(off, 0, true); off += 4; // 0 switchNames
            const resp = encodeResponse(req.id, true, buf.subarray(0, off));
            this.sendToClient(encodeFrame(Kind.Response, resp));
            break;
          }

          case Method.Backtrace: {
            const buf = new Uint8Array(6);
            buf[0] = Core.Cpu0;
            buf[1] = 0;
            new DataView(buf.buffer).setUint32(2, 0, true);
            const resp = encodeResponse(req.id, true, buf);
            this.sendToClient(encodeFrame(Kind.Response, resp));
            break;
          }

          case Method.ReadRegister: {
            const regVal = encodeU32(0x08001234);
            const resp = encodeResponse(req.id, true, regVal);
            this.sendToClient(encodeFrame(Kind.Response, resp));
            break;
          }

          case Method.ReadMemory: {
            const memSlice = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
            const memWire = new Uint8Array(4 + memSlice.length);
            new DataView(memWire.buffer).setUint32(0, memSlice.length, true);
            memWire.set(memSlice, 4);
            const resp = encodeResponse(req.id, true, memWire);
            this.sendToClient(encodeFrame(Kind.Response, resp));
            break;
          }

          case Method.Metrics: {
            const report = {
              hostCpuPercent: 25,
              hostRssMb: 64,
              hostThreads: 4,
              cpu0LoadPercent: 88,
              cpu0Pinned: 1,
              cpu0RamUsedBytes: 0x2000,
              cpu0RamTotalBytes: 0x10000,
              cpu1LoadPercent: 5,
              cpu1Pinned: 0,
              cpu1RamUsedBytes: 0x1000,
              cpu1RamTotalBytes: 0x8000,
            };
            const resp = encodeResponse(req.id, true, encodeMetricsReport(report));
            this.sendToClient(encodeFrame(Kind.Response, resp));
            break;
          }

          default: {
            const resp = encodeResponse(req.id, false, ErrorCode.UnknownMethod);
            this.sendToClient(encodeFrame(Kind.Response, resp));
            break;
          }
        }
      }
    }
  }

  sendToClient(packet) {
    if (this.client && this.client.onmessage) {
      setTimeout(() => {
        const ab = packet.buffer.slice(packet.byteOffset, packet.byteOffset + packet.byteLength);
        this.client.onmessage({ data: ab });
      }, 2);
    }
  }

  emitEvent(topic, payload) {
    const eventPayload = encodeEvent(topic, payload);
    const packet = encodeFrame(Kind.Event, eventPayload);
    this.sendToClient(packet);
  }
}

let activeMockServer = null;

class MockWebSocket {
  constructor(url) {
    this.url = url;
    this.readyState = 0; // CONNECTING
    this.binaryType = 'arraybuffer';
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;

    activeMockServer = new MockWebSocketServer();
    activeMockServer.attach(this);

    setTimeout(() => {
      this.readyState = 1; // OPEN
      if (this.onopen) this.onopen({});
    }, 5);
  }

  send(data) {
    if (activeMockServer) {
      setTimeout(() => {
        activeMockServer.handleClientFrame(data);
      }, 2);
    }
  }

  close(code = 1000, reason = 'Normal closure') {
    this.readyState = 3; // CLOSED
    if (this.onclose) {
      this.onclose({ code, reason });
    }
  }
}

await runAsyncTest('full client RPC workflow against mock WebSocket server', async () => {
  // Step 1: Initialize RA8RpcClient with MockWebSocketClass
  const client = new RA8RpcClient({ WebSocketClass: MockWebSocket });
  const hello = await client.connect('ws://127.0.0.1:24880');
  assert.equal(hello.magic, PROTOCOL_MAGIC);
  assert.equal(hello.version, PROTOCOL_VERSION);
  assert.equal(client.isConnected, true);
  assert.equal(client.connectTimer, null);

  // Step 2: Test step()
  const stepAck = await client.step(Core.Cpu0);
  assert.equal(stepAck, true);

  // Step 3: Test run()
  const runAck = await client.run(Core.Cpu0, RunMode.Run, 1000n);
  assert.equal(runAck, true);

  // Step 4: Test pause()
  const pauseAck = await client.pause(Core.Cpu0);
  assert.equal(pauseAck, true);

  // Step 5: Test readRegister()
  const pc = await client.readRegister(Core.Cpu0, Register.Pc);
  assert.equal(pc, 0x08001234);

  // Step 6: Test readMemory()
  const mem = await client.readMemory(Core.Cpu0, 0x20000000, 4);
  assert.deepEqual(Array.from(mem), [0xde, 0xad, 0xbe, 0xef]);

  // Step 7: Test writeMemory()
  const writeOk = await client.writeMemory(Core.Cpu0, 0x20000000, new Uint8Array([1, 2]));
  assert.equal(writeOk, true);

  // Step 8: Test getMetrics()
  const metrics = await client.getMetrics();
  assert.equal(metrics.hostCpuPercent, 25);
  assert.equal(metrics.hostRssMb, 64);
  assert.equal(metrics.cpu0LoadPercent, 88);
  assert.equal(metrics.cpu0Pinned, 1);
  assert.equal(metrics.cpu0RamUsedBytes, 0x2000);

  // Step 8b: Test setSpeed, getBoardParts, getBacktrace, sendInput, sendConsoleInput
  const speedOk = await client.setSpeed(Core.Cpu0, 100);
  assert.equal(speedOk, true);

  const parts = await client.getBoardParts();
  assert.equal(parts.panel, 'MockPanel');
  assert.equal(parts.panelWidth, 1024);
  assert.equal(parts.panelHeight, 600);

  const bt = await client.getBacktrace(Core.Cpu0);
  assert.equal(bt.count, 0);
  assert.equal(bt.frames.length, 0);

  const touchOk = await client.sendInput({ core: Core.Cpu0, kind: 1, x: 100, y: 100 });
  assert.equal(touchOk, true);

  const consoleOk = await client.sendConsoleInput(Core.Cpu0, new Uint8Array([65, 66]));
  assert.equal(consoleOk, true);

  // Step 9: Test subscribe and event emission
  const subAck = await client.subscribe(Core.Cpu0, Topic.LcdDirty);
  assert.equal(subAck, true);

  // Mock server emits lcd_dirty event
  let receivedDirtyRect = null;
  client.on('lcd_dirty', rect => {
    receivedDirtyRect = rect;
  });

  const testDirtyRect = {
    core: Core.Cpu0,
    x: 10,
    y: 20,
    width: 2,
    height: 1,
    virtualNs: 9999n,
    pixels: new Uint8Array([50, 100]),
  };
  activeMockServer.emitEvent(Topic.LcdDirty, encodeDirtyRect(testDirtyRect));

  // Wait briefly for event delivery
  await new Promise(r => setTimeout(r, 20));
  assert.notEqual(receivedDirtyRect, null);
  assert.equal(receivedDirtyRect.x, 10);
  assert.equal(receivedDirtyRect.y, 20);
  assert.deepEqual(Array.from(receivedDirtyRect.pixels), [50, 100]);

  // Step 10: Disconnect cleanly
  client.disconnect();
  assert.equal(client.isConnected, false);
});

console.log(`\n=== Test Results: ${testsPassed} passed, ${testsFailed} failed ===`);
if (testsFailed > 0) {
  process.exit(1);
}
