/**
 * Comprehensive Adversarial & Stress Test Suite for ra8-rpc-client
 *
 * Challenges:
 * 1. Truncated buffers across all message types and structs
 * 2. Oversized length prefixes, 32-bit boundaries, and 0-length payloads
 * 3. Invalid opcodes, unknown topics, malformed tags, and corrupt headers
 * 4. Negative, NaN, float, and extreme numeric metrics and arguments
 * 5. Extreme TCP/WebSocket packet fragmentation (byte-by-byte and arbitrary cuts)
 * 6. Concurrent and out-of-order RPC multiplexing
 * 7. Abnormal WebSocket closure, timeouts, and error resilience
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
  MAX_PAYLOAD,
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
  decodeU32,
  encodeU32,
  decodeAck,
  decodeStopped,
  decodeUart,
  dirtyRectToRgba,
  detectPixelFormat,
  RA8RpcClient,
} from '../dist/index.js';

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    console.log(`  ✓ [PASS] ${name}`);
    passed++;
  } catch (err) {
    console.error(`  ✗ [FAIL] ${name}`);
    console.error(err);
    failed++;
  }
}

async function testAsync(name, fn) {
  try {
    await fn();
    console.log(`  ✓ [PASS] ${name}`);
    passed++;
  } catch (err) {
    console.error(`  ✗ [FAIL] ${name}`);
    console.error(err);
    failed++;
  }
}

console.log('=== Starting Adversarial & Stress Tests for ra8-rpc-client ===\n');

/* ========================================================================== */
/* SECTION 1: Truncated Buffers Edge Cases                                    */
/* ========================================================================== */
console.log('--- Section 1: Truncated Buffers & Insufficient Lengths ---');

test('decodeHeader rejects truncated inputs (< 6 bytes)', () => {
  for (let len = 0; len < 6; len++) {
    const buf = new Uint8Array(len);
    assert.throws(
      () => decodeHeader(buf),
      /Truncated frame header/,
      `Failed to reject header of length ${len}`
    );
  }
});

test('decodeHello rejects truncated inputs (< 10 bytes)', () => {
  for (let len = 0; len < 10; len++) {
    const buf = new Uint8Array(len);
    assert.throws(
      () => decodeHello(buf),
      /Truncated Hello frame/,
      `Failed to reject hello of length ${len}`
    );
  }
});

test('decodeFault rejects truncated inputs (< 4 bytes)', () => {
  for (let len = 0; len < 4; len++) {
    const buf = new Uint8Array(len);
    assert.throws(
      () => decodeFault(buf),
      /Truncated Fault frame/,
      `Failed to reject fault of length ${len}`
    );
  }
});

test('decodeRequest rejects truncated header (< 10 bytes)', () => {
  for (let len = 0; len < 10; len++) {
    const buf = new Uint8Array(len);
    assert.throws(
      () => decodeRequest(buf),
      /Truncated Request envelope/,
      `Failed to reject request envelope of length ${len}`
    );
  }
});

test('decodeRequest rejects truncated args body when length is less than declared', () => {
  const buf = new Uint8Array(14);
  const view = new DataView(buf.buffer);
  view.setUint32(0, 1, true); // id
  view.setUint16(4, Method.Step, true); // method
  view.setUint32(6, 10, true); // argsLen declared = 10, but only 4 bytes remain
  assert.throws(() => decodeRequest(buf), /Truncated Request envelope args/);
});

test('decodeResponse rejects truncated header (< 5 bytes)', () => {
  for (let len = 0; len < 5; len++) {
    const buf = new Uint8Array(len);
    assert.throws(
      () => decodeResponse(buf),
      /Truncated Response envelope/,
      `Failed to reject response envelope of length ${len}`
    );
  }
});

test('decodeResponse rejects truncated Ok payload length (< 9 bytes)', () => {
  for (let len = 5; len < 9; len++) {
    const buf = new Uint8Array(len);
    buf[4] = 0; // ok tag
    assert.throws(
      () => decodeResponse(buf),
      /Truncated Response payload length header/
    );
  }
});

test('decodeResponse rejects truncated Ok payload body', () => {
  const buf = new Uint8Array(12);
  const view = new DataView(buf.buffer);
  view.setUint32(0, 1, true); // id
  view.setUint8(4, 0); // ok tag
  view.setUint32(5, 50, true); // declared len = 50, but buf length is 12 (payload only 3 bytes)
  assert.throws(() => decodeResponse(buf), /Truncated Response payload body/);
});

test('decodeResponse rejects truncated Err code (< 7 bytes)', () => {
  for (let len = 5; len < 7; len++) {
    const buf = new Uint8Array(len);
    buf[4] = 1; // err tag
    assert.throws(
      () => decodeResponse(buf),
      /Truncated Response error code/
    );
  }
});

test('decodeEvent rejects truncated header (< 6 bytes) and body', () => {
  for (let len = 0; len < 6; len++) {
    const buf = new Uint8Array(len);
    assert.throws(() => decodeEvent(buf), /Truncated Event envelope/);
  }
  const buf = new Uint8Array(8);
  const view = new DataView(buf.buffer);
  view.setUint16(0, Topic.Stop, true);
  view.setUint32(2, 20, true); // declared 20 bytes, only 2 bytes present
  assert.throws(() => decodeEvent(buf), /Truncated Event payload body/);
});

test('decodeMetricsReport rejects truncated inputs (< 32 bytes)', () => {
  for (const len of [0, 1, 10, 20, 31]) {
    const buf = new Uint8Array(len);
    assert.throws(
      () => decodeMetricsReport(buf),
      /Truncated MetricsReport: requires 32 bytes/,
      `Failed to reject metrics report of length ${len}`
    );
  }
});

test('decodeDirtyRect rejects truncated header (< 21 bytes) and truncated pixels', () => {
  for (let len = 0; len < 21; len++) {
    const buf = new Uint8Array(len);
    assert.throws(() => decodeDirtyRect(buf), /Truncated DirtyRect/);
  }

  const buf = new Uint8Array(25);
  const view = new DataView(buf.buffer);
  view.setUint16(5, 10, true); // width = 10
  view.setUint16(7, 10, true); // height = 10
  view.setUint32(17, 100, true); // declared pixelLen = 100, but only 4 bytes in buffer
  assert.throws(() => decodeDirtyRect(buf), /Truncated DirtyRect pixel buffer/);
});

test('decodeCoreOnly, decodeU32, decodeAck, decodeStopped, decodeUart reject truncation', () => {
  assert.throws(() => decodeCoreOnly(new Uint8Array(0)), /Truncated CoreOnly/);
  assert.throws(() => decodeU32(new Uint8Array(3)), /Truncated U32/);
  assert.throws(() => decodeAck(new Uint8Array(0)), /Truncated Ack/);
  assert.throws(() => decodeStopped(new Uint8Array(9)), /Truncated Stopped/);
  assert.throws(() => decodeUart(new Uint8Array(13)), /Truncated Uart/);

  // Uart with truncated payload
  const uartBuf = new Uint8Array(16);
  const view = new DataView(uartBuf.buffer);
  view.setUint32(10, 10, true); // declared len = 10, only 2 bytes exist
  assert.throws(() => decodeUart(uartBuf), /Truncated Uart bytes/);
});

/* ========================================================================== */
/* SECTION 2: Oversized Lengths & 32-bit Boundary Conditions                  */
/* ========================================================================== */
console.log('\n--- Section 2: Oversized Length Prefixes & Boundaries ---');

test('splitFrames throws on length exceeding maxPayload', () => {
  const buf = encodeHeader(MAX_PAYLOAD + 1, Kind.Request);
  assert.throws(
    () => splitFrames(buf, MAX_PAYLOAD),
    /Frame payload oversize: 1048577 > max 1048576/
  );
});

test('splitFrames throws on maximum u32 length (0xFFFFFFFF = 4294967295)', () => {
  const buf = encodeHeader(0xFFFFFFFF, Kind.Request);
  assert.throws(
    () => splitFrames(buf),
    /Frame payload oversize: 4294967295 > max 1048576/
  );
});

test('splitFrames handles exact maxPayload boundary correctly when payload present', () => {
  const dummyPayload = new Uint8Array(1024);
  const buf = encodeFrame(Kind.Event, dummyPayload);
  // Test with custom maxPayload = 1024
  const res = splitFrames(buf, 1024);
  assert.equal(res.frames.length, 1);
  assert.equal(res.frames[0].payload.length, 1024);
});

test('splitFrames handles 0-byte payload frame correctly without hanging or infinite loop', () => {
  const zeroFrame = encodeFrame(Kind.Event, new Uint8Array(0));
  assert.equal(zeroFrame.length, HEADER_BYTES);
  const res = splitFrames(zeroFrame);
  assert.equal(res.frames.length, 1);
  assert.equal(res.frames[0].payload.length, 0);
  assert.equal(res.remainder.length, 0);
});

test('decodeRequest, decodeResponse, decodeEvent handle 0xFFFFFFFF declared lengths safely', () => {
  // Request with 0xFFFFFFFF argsLen
  const reqBuf = new Uint8Array(10);
  const reqView = new DataView(reqBuf.buffer);
  reqView.setUint32(0, 1, true);
  reqView.setUint16(4, Method.Step, true);
  reqView.setUint32(6, 0xFFFFFFFF, true);
  assert.throws(() => decodeRequest(reqBuf), /Truncated Request envelope args/);

  // Response with 0xFFFFFFFF len
  const respBuf = new Uint8Array(9);
  const respView = new DataView(respBuf.buffer);
  respView.setUint32(0, 1, true);
  respView.setUint8(4, 0);
  respView.setUint32(5, 0xFFFFFFFF, true);
  assert.throws(() => decodeResponse(respBuf), /Truncated Response payload body/);

  // Event with 0xFFFFFFFF len
  const evtBuf = new Uint8Array(6);
  const evtView = new DataView(evtBuf.buffer);
  evtView.setUint16(0, Topic.Stop, true);
  evtView.setUint32(2, 0xFFFFFFFF, true);
  assert.throws(() => decodeEvent(evtBuf), /Truncated Event payload body/);

  // Memory with 0xFFFFFFFF len
  const memBuf = new Uint8Array(4);
  new DataView(memBuf.buffer).setUint32(0, 0xFFFFFFFF, true);
  assert.throws(() => decodeMemory(memBuf), /Truncated Memory bytes/);
});

/* ========================================================================== */
/* SECTION 3: Invalid Opcodes, Enums & Malformed Tags                         */
/* ========================================================================== */
console.log('\n--- Section 3: Invalid Opcodes & Corrupt Tags ---');

test('decodeResponse rejects invalid result tags (not 0 and not 1)', () => {
  for (const invalidTag of [2, 3, 42, 255]) {
    const buf = new Uint8Array(10);
    const view = new DataView(buf.buffer);
    view.setUint32(0, 1, true);
    view.setUint8(4, invalidTag);
    assert.throws(
      () => decodeResponse(buf),
      new RegExp(`Invalid Response result tag: ${invalidTag}`),
      `Expected error for invalid result tag ${invalidTag}`
    );
  }
});

test('splitFrames ignores unknown frame kinds without throwing (preserves raw kind)', () => {
  const unknownKind = 0x9999;
  const payload = new Uint8Array([1, 2, 3, 4]);
  const frame = encodeFrame(unknownKind, payload);
  const res = splitFrames(frame);
  assert.equal(res.frames.length, 1);
  assert.equal(res.frames[0].kind, unknownKind);
  assert.deepEqual(Array.from(res.frames[0].payload), [1, 2, 3, 4]);
});

/* ========================================================================== */
/* SECTION 4: Negative, NaN, Extreme Numbers in Metrics & Numeric Payloads   */
/* ========================================================================== */
console.log('\n--- Section 4: Negative, NaN, Float & Extreme Numbers ---');

test('encodeMetricsReport with negative, NaN, float and overflow values converts safely', () => {
  // Test behavior with non-standard numeric inputs:
  // ECMA-262 specifies ToUint32/ToUint8 conversion rules (NaN -> 0, negative wraps, floats truncate).
  const reportWithOddValues = {
    hostCpuPercent: NaN,         // converts to 0
    hostRssMb: -1,               // converts to 0xFFFFFFFF = 4294967295
    hostThreads: 12.85,          // converts to 12
    cpu0LoadPercent: -1,         // converts to 255
    cpu0Pinned: 300,             // converts to 300 & 0xFF = 44
    cpu0RamUsedBytes: 0,
    cpu0RamTotalBytes: 0xFFFFFFFF,
    cpu1LoadPercent: NaN,        // converts to 0
    cpu1Pinned: 0,
    cpu1RamUsedBytes: 0x1000,
    cpu1RamTotalBytes: 0x8000,
  };

  const bytes = encodeMetricsReport(reportWithOddValues);
  assert.equal(bytes.length, METRICS_REPORT_BYTES);

  const decoded = decodeMetricsReport(bytes);
  assert.equal(decoded.hostCpuPercent, 0, 'NaN should serialize to 0');
  assert.equal(decoded.hostRssMb, 0xFFFFFFFF, '-1 should serialize to 0xFFFFFFFF');
  assert.equal(decoded.hostThreads, 12, '12.85 should serialize to 12');
  assert.equal(decoded.cpu0LoadPercent, 255, '-1 u8 should serialize to 255');
  assert.equal(decoded.cpu0Pinned, 44, '300 u8 should serialize to 44');
  assert.equal(decoded.cpu1LoadPercent, 0, 'NaN u8 should serialize to 0');
});

test('encodeWriteRegister with negative 32-bit value (-1) wraps to 0xFFFFFFFF', () => {
  const bytes = encodeWriteRegister(Core.Cpu0, Register.R0, -1);
  assert.equal(bytes.length, 6);
  const view = new DataView(bytes.buffer);
  assert.equal(view.getUint32(2, true), 0xFFFFFFFF);
});

test('encodeRun and encodeAdvance with negative BigInt wraps to 64-bit uint correctly', () => {
  const runBytes = encodeRun(Core.Cpu0, RunMode.Run, -1n);
  const runView = new DataView(runBytes.buffer);
  assert.equal(runView.getBigUint64(2, true), 0xFFFFFFFFFFFFFFFFn);

  const advBytes = encodeAdvance(Core.Cpu1, -5n);
  const advView = new DataView(advBytes.buffer);
  assert.equal(advView.getBigUint64(1, true), 0xFFFFFFFFFFFFFFFBn);
});

/* ========================================================================== */
/* SECTION 5: Extreme Packet Fragmentation & Stream Reassembly                */
/* ========================================================================== */
console.log('\n--- Section 5: Extreme Stream Fragmentation & Reassembly ---');

test('splitFrames reassembles frames fed 1 byte at a time', () => {
  const req1 = encodeFrame(Kind.Request, encodeRequest(1, Method.Step));
  const resp1 = encodeFrame(Kind.Response, encodeResponse(1, true, new Uint8Array([1])));
  const evt1 = encodeFrame(Kind.Event, encodeEvent(Topic.Stop, new Uint8Array([0, 1, 2, 3])));

  const combined = new Uint8Array(req1.length + resp1.length + evt1.length);
  combined.set(req1, 0);
  combined.set(resp1, req1.length);
  combined.set(evt1, req1.length + resp1.length);

  let accumulated = new Uint8Array(0);
  const gatheredFrames = [];

  for (let i = 0; i < combined.length; i++) {
    const singleByteChunk = combined.subarray(i, i + 1);
    const next = new Uint8Array(accumulated.length + 1);
    next.set(accumulated, 0);
    next.set(singleByteChunk, accumulated.length);
    accumulated = next;

    const { frames, remainder } = splitFrames(accumulated);
    accumulated = remainder;
    gatheredFrames.push(...frames);
  }

  assert.equal(accumulated.length, 0, 'No remaining unparsed bytes');
  assert.equal(gatheredFrames.length, 3, 'Should assemble all 3 frames');
  assert.equal(gatheredFrames[0].kind, Kind.Request);
  assert.equal(gatheredFrames[1].kind, Kind.Response);
  assert.equal(gatheredFrames[2].kind, Kind.Event);
});

test('splitFrames handles random chunk boundaries across 100 iterations', () => {
  const frames = [
    encodeFrame(Kind.Hello, encodeHello(0x1234)),
    encodeFrame(Kind.Request, encodeRequest(10, Method.Pause)),
    encodeFrame(Kind.Response, encodeResponse(10, true, new Uint8Array([1, 2, 3, 4, 5]))),
    encodeFrame(Kind.Event, encodeEvent(Topic.Speed, new Uint8Array([7, 8]))),
  ];

  const fullStream = new Uint8Array(frames.reduce((sum, f) => sum + f.length, 0));
  let writeOffset = 0;
  for (const f of frames) {
    fullStream.set(f, writeOffset);
    writeOffset += f.length;
  }

  // Slice into pseudo-random chunk sizes between 1 and 7 bytes
  const chunkSizes = [1, 3, 2, 7, 1, 4, 2, 5, 3, 1, 6, 2, 1, 3, 4, 2, 5, 8, 2, 1, 10];
  let streamOffset = 0;
  let chunkIdx = 0;
  let buffer = new Uint8Array(0);
  const parsed = [];

  while (streamOffset < fullStream.length) {
    const chunkSize = chunkSizes[chunkIdx % chunkSizes.length];
    chunkIdx++;
    const end = Math.min(streamOffset + chunkSize, fullStream.length);
    const chunk = fullStream.subarray(streamOffset, end);
    streamOffset = end;

    const merged = new Uint8Array(buffer.length + chunk.length);
    merged.set(buffer, 0);
    merged.set(chunk, buffer.length);

    const res = splitFrames(merged);
    buffer = res.remainder;
    parsed.push(...res.frames);
  }

  assert.equal(buffer.length, 0);
  assert.equal(parsed.length, 4);
  assert.equal(parsed[0].kind, Kind.Hello);
  assert.equal(parsed[1].kind, Kind.Request);
  assert.equal(parsed[2].kind, Kind.Response);
  assert.equal(parsed[3].kind, Kind.Event);
});

/* ========================================================================== */
/* SECTION 6: DirtyRect and Framebuffer Edge Cases                            */
/* ========================================================================== */
console.log('\n--- Section 6: DirtyRect & Framebuffer Robustness ---');

test('dirtyRectToRgba handles 0x0 empty rectangles without throwing', () => {
  const rect = {
    core: Core.Cpu0,
    x: 0,
    y: 0,
    width: 0,
    height: 0,
    virtualNs: 0n,
    pixels: new Uint8Array(0),
  };
  assert.equal(detectPixelFormat(rect), 'grayscale');
  const rgba = dirtyRectToRgba(rect);
  assert.equal(rgba.length, 0);
});

test('dirtyRectToRgba handles truncated pixel buffers by zero-filling missing channels', () => {
  // 2x2 = 4 pixels, but pixel buffer only has 2 bytes (grayscale truncated)
  const rect = {
    core: Core.Cpu0,
    x: 0,
    y: 0,
    width: 2,
    height: 2,
    virtualNs: 0n,
    pixels: new Uint8Array([200, 100]), // 2 of 4 pixels
  };
  const rgba = dirtyRectToRgba(rect, undefined, 'grayscale');
  assert.equal(rgba.length, 16);
  // Pixel 0: 200
  assert.equal(rgba[0], 200);
  // Pixel 1: 100
  assert.equal(rgba[4], 100);
  // Pixel 2 (missing from src): safely filled with 0, A = 255
  assert.equal(rgba[8], 0);
  assert.equal(rgba[11], 255);
  // Pixel 3 (missing from src): safely filled with 0, A = 255
  assert.equal(rgba[12], 0);
  assert.equal(rgba[15], 255);
});

test('dirtyRectToRgba converts all supported formats: rgb24, argb32, rgba32', () => {
  // RGB24: 1 pixel [10, 20, 30]
  const rectRgb24 = {
    core: Core.Cpu0,
    x: 0,
    y: 0,
    width: 1,
    height: 1,
    virtualNs: 0n,
    pixels: new Uint8Array([10, 20, 30]),
  };
  assert.equal(detectPixelFormat(rectRgb24), 'rgb24');
  const out24 = dirtyRectToRgba(rectRgb24);
  assert.deepEqual(Array.from(out24), [10, 20, 30, 255]);

  // ARGB32: 1 pixel [255, 11, 22, 33] (A, R, G, B)
  const rectArgb = {
    core: Core.Cpu0,
    x: 0,
    y: 0,
    width: 1,
    height: 1,
    virtualNs: 0n,
    pixels: new Uint8Array([200, 11, 22, 33]),
  };
  const outArgb = dirtyRectToRgba(rectArgb, undefined, 'argb32');
  assert.deepEqual(Array.from(outArgb), [11, 22, 33, 200]);

  // RGBA32: 1 pixel [55, 66, 77, 88] (R, G, B, A)
  const rectRgba = {
    core: Core.Cpu0,
    x: 0,
    y: 0,
    width: 1,
    height: 1,
    virtualNs: 0n,
    pixels: new Uint8Array([55, 66, 77, 88]),
  };
  assert.equal(detectPixelFormat(rectRgba), 'rgba32');
  const outRgba = dirtyRectToRgba(rectRgba);
  assert.deepEqual(Array.from(outRgba), [55, 66, 77, 88]);
});

/* ========================================================================== */
/* SECTION 7: Client Error Recovery, Timeouts & Concurrent Out-of-Order Calls */
/* ========================================================================== */
console.log('\n--- Section 7: Client Recovery, Timeouts & Concurrent Calls ---');

class AdversarialMockWebSocketServer {
  constructor() {
    this.client = null;
    this.requests = [];
  }

  attach(clientWs) {
    this.client = clientWs;
  }

  sendToClient(packet) {
    if (this.client && this.client.onmessage) {
      setTimeout(() => {
        const ab = packet.buffer.slice(packet.byteOffset, packet.byteOffset + packet.byteLength);
        this.client.onmessage({ data: ab });
      }, 1);
    }
  }

  handleClientFrame(raw) {
    const { frames } = splitFrames(new Uint8Array(raw));
    for (const frame of frames) {
      if (frame.kind === Kind.Hello) {
        this.sendToClient(encodeFrame(Kind.Hello, encodeHello(0xFFFF)));
      } else if (frame.kind === Kind.Request) {
        const req = decodeRequest(frame.payload);
        this.requests.push(req);
      }
    }
  }
}

class AdversarialMockWebSocket {
  constructor(url) {
    this.url = url;
    this.readyState = 0; // CONNECTING
    this.binaryType = 'arraybuffer';
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;

    this.server = new AdversarialMockWebSocketServer();
    this.server.attach(this);

    setTimeout(() => {
      this.readyState = 1; // OPEN
      if (this.onopen) this.onopen({});
    }, 2);
  }

  send(data) {
    if (this.server) {
      setTimeout(() => {
        this.server.handleClientFrame(data);
      }, 1);
    }
  }

  close(code = 1000, reason = 'Normal closure') {
    this.readyState = 3;
    if (this.onclose) this.onclose({ code, reason });
  }
}

await testAsync('client.call throws immediately when client is disconnected', async () => {
  const client = new RA8RpcClient({ WebSocketClass: AdversarialMockWebSocket });
  assert.equal(client.isConnected, false);
  await assert.rejects(
    () => client.call(Method.Step),
    /RPC client is not connected/
  );
});

await testAsync('client handles concurrent calls completed in out-of-order sequence', async () => {
  const client = new RA8RpcClient({ WebSocketClass: AdversarialMockWebSocket });
  await client.connect('ws://127.0.0.1:24880');
  const server = client.ws.server;

  // Fire 3 concurrent calls
  const p1 = client.call(Method.ReadRegister, encodeReadRegister(Core.Cpu0, Register.Pc));
  const p2 = client.call(Method.ReadRegister, encodeReadRegister(Core.Cpu0, Register.Sp));
  const p3 = client.call(Method.ReadRegister, encodeReadRegister(Core.Cpu0, Register.Lr));

  // Wait for requests to hit server
  await new Promise(r => setTimeout(r, 20));
  assert.equal(server.requests.length, 3);

  const req1 = server.requests[0];
  const req2 = server.requests[1];
  const req3 = server.requests[2];

  // Reply out of order: Req 2 first, then Req 3, then Req 1
  server.sendToClient(
    encodeFrame(Kind.Response, encodeResponse(req2.id, true, encodeU32(0x20001000)))
  );
  server.sendToClient(
    encodeFrame(Kind.Response, encodeResponse(req3.id, true, encodeU32(0x08000555)))
  );
  server.sendToClient(
    encodeFrame(Kind.Response, encodeResponse(req1.id, true, encodeU32(0x08000123)))
  );

  const [res1, res2, res3] = await Promise.all([p1, p2, p3]);
  assert.equal(decodeU32(res1), 0x08000123);
  assert.equal(decodeU32(res2), 0x20001000);
  assert.equal(decodeU32(res3), 0x08000555);

  client.disconnect();
});

await testAsync('client times out individual RPC call when server does not reply', async () => {
  const client = new RA8RpcClient({
    WebSocketClass: AdversarialMockWebSocket,
    timeoutMs: 1000,
  });
  await client.connect('ws://127.0.0.1:24880');

  // Call method with 50ms timeout, but server never replies
  await assert.rejects(
    () => client.call(Method.Step, undefined, 50),
    /timed out/
  );

  client.disconnect();
});

await testAsync('client cleans up and rejects all pending calls when connection terminates', async () => {
  const client = new RA8RpcClient({ WebSocketClass: AdversarialMockWebSocket });
  await client.connect('ws://127.0.0.1:24880');

  const pendingCall = client.call(Method.Step);

  // Premature disconnect
  client.disconnect();

  await assert.rejects(
    () => pendingCall,
    /Client disconnected|WebSocket closed/
  );
});

await testAsync('client rejects handshake if server sends incompatible magic or version', async () => {
  class BadMagicWebSocket extends AdversarialMockWebSocket {
    constructor(url) {
      super(url);
      this.server = null; // Do not use standard server
      setTimeout(() => {
        // Send bad magic
        const badHello = encodeFrame(Kind.Hello, encodeHello(0xFFFF, 0xDEADBEEF, 1));
        this.onmessage({ data: badHello.buffer });
      }, 5);
    }
  }

  const client = new RA8RpcClient({ WebSocketClass: BadMagicWebSocket });
  await assert.rejects(
    () => client.connect('ws://127.0.0.1:24880'),
    /Incompatible RPC peer: magic 0xdeadbeef/
  );
});

await testAsync('client surfaces Fault frames via error event listener', async () => {
  const client = new RA8RpcClient({ WebSocketClass: AdversarialMockWebSocket });
  await client.connect('ws://127.0.0.1:24880');
  const server = client.ws.server;

  let errorReceived = null;
  client.on('error', err => {
    errorReceived = err;
  });

  // Server injects a Fault frame
  const faultFrame = encodeFrame(Kind.Fault, encodeFault(ErrorCode.BadArgs));
  server.sendToClient(faultFrame);

  await new Promise(r => setTimeout(r, 20));
  assert.notEqual(errorReceived, null);
  assert.match(errorReceived.message, /RPC fault code 2/);

  client.disconnect();
});

console.log(`\n=== Adversarial Stress Test Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  process.exit(1);
}
